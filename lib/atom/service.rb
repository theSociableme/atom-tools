require "uri"

require "atom/http"
require "atom/element"
require "atom/collection"

module Atom
  PP_NS = "http://purl.org/atom/app#"
  
  class WrongNamespace < RuntimeError #:nodoc:
  end
  class WrongMimetype < RuntimeError # :nodoc:
  end
  class WrongResponse < RuntimeError # :nodoc:
  end

  # an Atom::Workspace has a #title (Atom::Text) and #collections, an Array of Atom::Collection s
  class Workspace < Atom::Element
    element :collections, Atom::Multiple(Atom::Collection)
    element :title, Atom::Text

    def self.parse(xml, base = "", http = Atom::HTTP.new) # :nodoc:
      ws = Atom::Workspace.new("workspace")

      rxml = if xml.is_a? REXML::Document
        xml.root
      elsif xml.is_a? REXML::Element
        xml
      else 
        REXML::Document.new(xml)
      end

      xml.fill_text_construct(ws, "title")

      REXML::XPath.match( rxml, 
                          "./app:collection",
                          {"app" => Atom::PP_NS} ).each do |col_el|
        # absolutize relative URLs
        url = base.to_uri + col_el.attributes["href"].to_uri
       
        coll = Atom::Collection.new(url, http)

        # XXX this is a Text Construct, and should be parsed as such
        col_el.fill_text_construct(coll, "title")

        accepts = REXML::XPath.first( col_el,
                                      "./app:accept",
                                      {"app" => Atom::PP_NS} )
        coll.accepts = (accepts ? accepts.text : "entry")
        
        ws.collections << coll
      end

      ws
    end

    def to_element # :nodoc:
      root = REXML::Element.new "workspace" 

      # damn you, REXML. Damn you and you bizarre handling of namespaces
      title = self.title.to_element
      title.name = "atom:title"
      root << title

      self.collections.each do |coll|
        el = REXML::Element.new "collection"

        el.attributes["href"] = coll.uri

        title = coll.title.to_element
        title.name = "atom:title"
        el << title
       
        unless coll.accepts.nil?
          accepts = REXML::Element.new "accepts"
          accepts.text = coll.accepts
          el << accepts
        end

        root << el
      end

      root
    end
  end

  # Atom::Service represents an Atom Publishing Protocol service
  # document. Its only child is #workspaces, which is an Array of 
  # Atom::Workspace s
  class Service < Atom::Element
    element :workspaces, Atom::Multiple(Atom::Workspace)

    # retrieves and parses an Atom service document.
    def initialize(service_url = "", http = Atom::HTTP.new)
      super("service")
      
      @http = http

      return if service_url.empty?

      base = URI.parse(service_url)

      rxml = nil

      res = @http.get(base)

      unless res.code == "200" # XXX needs to handle redirects, &c.
        raise WrongResponse, "service document URL responded with unexpected code #{res.code}"
      end

      unless res.content_type == "application/atomserv+xml"
        raise WrongMimetype, "this isn't an atom service document!"
      end

      parse(res.body, base)
    end
 
    # parse a service document, adding its workspaces to this object
    def parse xml, base = ""
      rxml = if xml.is_a? REXML::Document
        xml.root
      elsif xml.is_a? REXML::Element
        xml
      else 
        REXML::Document.new(xml)
      end

      unless rxml.root.namespace == PP_NS
        raise WrongNamespace, "this isn't an atom service document!"
      end

      REXML::XPath.match( rxml, "/app:service/app:workspace", {"app" => Atom::PP_NS} ).each do |ws_el|
        self.workspaces << Atom::Workspace.parse(ws_el, base, @http)
      end

      self
    end

    # serialize to a (namespaced) REXML::Document 
    def to_xml
      doc = REXML::Document.new
      
      root = REXML::Element.new "service"
      root.add_namespace Atom::PP_NS
      root.add_namespace "atom", Atom::NS

      self.workspaces.each do |ws|
        root << ws.to_element
      end

      doc << root
      doc
    end
  end
 
  class Entry
    # the @href of an entry's link[@rel="edit"]
    def edit_url
      begin
        edit_link = self.links.find do |link|
          link["rel"] == "edit"
        end

        edit_link["href"]
      rescue
        nil
      end
    end
  end
end