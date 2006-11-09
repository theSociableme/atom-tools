require "atom/element"
require "atom/text"
require "atom/entry"

require "atom/http"

module Atom
  class HTTPException < RuntimeError # :nodoc:
  end
  class FeedGone < RuntimeError # :nodoc:
  end

  # A feed of entries. As an Atom::Element, it can be manipulated using
  # accessors for each of its child elements. You can set them with any
  # object that makes sense; they will be returned in the types listed.
  #
  # Feeds have the following children:
  #
  # id:: a universally unique IRI which permanently identifies the feed
  # title:: a human-readable title (Atom::Text)
  # subtitle:: a human-readable description or subtitle (Atom::Text)
  # updated:: the most recent Time the feed was modified in a way the publisher considers significant
  # generator:: the agent used to generate a feed
  # icon:: an IRI identifying an icon which visually identifies a feed (1:1 aspect ratio, looks OK small)
  # logo:: an IRI identifying an image which visually identifies a feed (2:1 aspect ratio)
  # rights:: rights held in and over a feed (Atom::Text)  
  #
  # There are also +links+, +categories+, +authors+, +contributors+ 
  # and +entries+, each of which is an Array of its respective type and
  # can be used thusly:
  #
  #   entry = feed.entries.new
  #   entry.title = "blah blah blah"
  class Feed < Atom::Element
    attr_reader :uri

    # the Atom::Feed pointed to by link[@rel='previous']
    attr_reader :prev
    # the Atom::Feed pointed to by link[@rel='next']
    attr_reader :next
   
    # conditional get information from the last fetch
    attr_reader :etag, :last_modified

    element :id, String, true
    element :title, Atom::Text, true
    element :subtitle, Atom::Text
   
    element :updated, Atom::Time, true

    element :links, Atom::Multiple(Atom::Link)
    element :categories, Atom::Multiple(Atom::Category)

    element :authors, Atom::Multiple(Atom::Author)
    element :contributors, Atom::Multiple(Atom::Contributor)

    element :generator, String # XXX with uri and version attributes!
    element :icon, String
    element :logo, String

    element :rights, Atom::Text
    
    element :entries, Atom::Multiple(Atom::Entry)

    include Enumerable

    def inspect # :nodoc:
      "<#{@uri} entries: #{entries.length} title='#{title}'>"
    end

    # parses XML fetched from +base+ into an Atom::Feed
    def self.parse xml, base = ""
      if xml.respond_to? :to_atom_entry
        xml.to_atom_feed(base)
      else
        REXML::Document.new(xml.to_s).to_atom_feed(base)
      end
    end

    # Create a new Feed that can be found at feed_uri and retrieved
    # using an Atom::HTTP object http
    def initialize feed_uri = nil, http = Atom::HTTP.new
      @entries = []
      @http = http

      if feed_uri
        @uri = feed_uri.to_uri
        self.base = feed_uri
      end

      super "feed"
    end

    # iterates over a feed's entries
    def each &block
      @entries.each &block
    end

    # gets everything in the logical feed (could be a lot of stuff)
    # (see <http://www.ietf.org/internet-drafts/draft-nottingham-atompub-feed-history-05.txt>)
    def get_everything!
      self.update!
  
      prev = @prev
      while prev
        prev.update!

        self.merge_entries! prev
        prev = prev.prev
      end

      nxt = @next
      while nxt
        nxt.update!

        self.merge_entries! nxt
        nxt = nxt.next
      end

      self
    end

    # merges the entries from another feed into this one
    def merge_entries! other_feed
      other_feed.each do |entry|
        # TODO: add atom:source elements
        self << entry
      end
    end

    # like #merge, but in place 
    def merge! other_feed
      [:id, :title, :subtitle, :updated, :rights].each { |p|
        self.send("#{p}=", other_feed.send("#{p}"))
      }

      [:links, :categories, :authors, :contributors].each do |p|
        other_feed.send("#{p}").each do |e|
          self.send("#{p}") << e
        end
      end

      merge_entries! other_feed
    end

    # merges "important" properties of this feed with another one,
    # returning a new feed
    def merge other_feed
      feed = self.clone

      feed.merge! other_feed
      
      feed
    end

    # fetches this feed's URL, parses the result and #merge!s
    # changes, new entries, &c.
    def update!
      raise(RuntimeError, "can't fetch without a uri.") unless @uri
     
      headers = {}
      headers["If-None-Match"] = @etag if @etag
      headers["If-Modified-Since"] = @last_modified if @last_modified

      res = @http.get(@uri, headers)

      if res.code == "304"
        # we're already all up to date
        return self
      elsif res.code == "410"
        raise Atom::FeedGone, "410 Gone (#{@uri})"
      elsif res.code != "200"
        raise Atom::HTTPException, "Unexpected HTTP response code: #{res.code}"
      end
        
      unless res.content_type.match(/^application\/atom\+xml/)
        raise Atom::HTTPException, "Unexpected HTTP response Content-Type: #{res.content_type} (wanted application/atom+xml)"
      end

      @etag = res["Etag"] if res["Etag"]
      @last_modified = res["Last-Modified"] if res["Last-Modified"]

      xml = res.body

      coll = REXML::Document.new(xml)

      update_time = Time.parse(REXML::XPath.first(coll, "/atom:feed/atom:updated", { "atom" => Atom::NS } ).text)

      # the feed hasn't been updated, don't bother
      if self.updated and self.updated >= update_time
        return self
      end

      coll = Atom::Feed.parse(coll, self.base.to_s)
      merge! coll
     
      link = coll.links.find { |l| l["rel"] = "next" and l["type"] == "application/atom+xml" }
      if link
        abs_uri = @uri + link["href"]
        @next = Feed.new(abs_uri.to_s, @http)
      end

      link = coll.links.find { |l| l["rel"] = "previous" and l["type"] == "application/atom+xml" } 
      if link
        abs_uri = @uri + link["href"]
        @prev = Feed.new(abs_uri.to_s, @http)
      end

      self
    end

    # adds an entry to this feed. if this feed already contains an 
    # entry with the same id, the newest one is used.
    def << entry
      existing = entries.find do |e|
        e.id == entry.id
      end

      if not existing
        @entries << entry
      elsif not existing.updated or (existing.updated and entry.updated and entry.updated >= existing.updated)
        @entries[@entries.index(existing)] = entry
      end
    end
  end
end

# this is here solely so you don't have to require it
require "atom/xml"