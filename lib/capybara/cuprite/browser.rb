require "base64"
require "forwardable"
require "cuprite/browser/process"
require "cuprite/browser/client"

module Capybara::Cuprite
  class Browser
    extend Forwardable

    def self.start(*args)
      new(*args)
    end

    delegate [:command, :wait] => :@client

    def initialize(options = nil)
      options ||= {}
      @process = Process.start(options)
      @client  = Client.new(@process.host, @process.port, options[:logger])
    end

    def visit(url)
      command("Page.enable")
      command("DOM.enable")
      command("CSS.enable")
      command("Runtime.enable")

      command("Page.navigate", url: url) do |response|
        wait(event: "Page.frameStoppedLoading", params: { frameId: response["frameId"] })
      end
    end

    def current_url
      response = command "Runtime.evaluate", expression: "location.href"
      response["result"]["value"]
    end

    def frame_url
      command "frame_url"
    end

    def status_code
      command "status_code"
    end

    def body
      response = command "DOM.getDocument", depth: 0
      response = command "DOM.getOuterHTML", nodeId: response["root"]["nodeId"]
      response["outerHTML"]
    end

    def source
      command "source"
    end

    def title
      command "title"
    end

    def frame_title
      command "frame_title"
    end

    def parents(page_id, id)
      command "parents", page_id, id
    end

    def find(_, selector)
      results = []
      command("DOM.getDocument", depth: 0) # Search doesn't work w/o it
      response = command "DOM.performSearch", query: selector
      search_id, count = response["searchId"], response["resultCount"]

      if count == 0
        command "DOM.discardSearchResults", searchId: search_id
        return results
      end

      response = command "DOM.getSearchResults", searchId: search_id, fromIndex: 0, toIndex: count
      results = response["nodeIds"].map do |node_id|
        node = command("DOM.describeNode", nodeId: node_id)["node"]
        next if node["nodeType"] != 1 # "nodeType":3, "nodeName":"#text" for eg
        node["nodeId"] = node_id
        node["selector"] = selector
        [nil, node] # FIXME: page_id
      end.compact

      # response = command("DOM.querySelectorAll", nodeId: response["root"]["nodeId"], selector: selector)
      # results = response["nodeIds"].map do |id|
      #   node = command("DOM.describeNode", nodeId: id)["node"]
      #   node["nodeId"] = id
      #   node["selector"] = selector
      #   [nil, node] # FIXME: page_id
      # end

      Array(results)
    end

    def find_within(page_id, id, method, selector)
      command "find_within", page_id, id, method, selector
    end

    def all_text(page_id, id)
      command "all_text", page_id, id
    end

    def visible_text(page_id, node)
      begin
        resolved = command "DOM.resolveNode", nodeId: node["nodeId"]
        object_id = resolved["object"]["objectId"]
      rescue BrowserError => e
        if e.message == "No node with given id found"
          raise ObsoleteNode.new(self, e.response)
        end

        raise
      end

      response = command "Runtime.callFunctionOn", objectId: object_id, functionDeclaration: <<~JS
        function () { return this.innerText; }
      JS
      response["result"]["value"]
    end

    def delete_text(page_id, id)
      command "delete_text", page_id, id
    end

    def property(page_id, id, name)
      command "property", page_id, id, name.to_s
    end

    def attributes(page_id, id)
      command "attributes", page_id, id
    end

    def attribute(page_id, id, name)
      command "attribute", page_id, id, name.to_s
    end

    def value(page_id, id)
      command "value", page_id, id
    end

    def set(page_id, id, value)
      command "set", page_id, id, value
    end

    def select_file(page_id, id, value)
      command "select_file", page_id, id, value
    end

    def tag_name(page_id, id)
      command("tag_name", page_id, id).downcase
    end

    def visible?(page_id, node)
      response = command "CSS.getComputedStyleForNode", nodeId: node["nodeId"]
      style = response["computedStyle"]
      display = style.find { |s| s["name"] == "display" }["value"]
      visibility = style.find { |s| s["name"] == "visibility" }["value"]
      opacity = style.find { |s| s["name"] == "opacity" }["value"]
      display == "none" || visibility == "hidden" || opacity == 0 ? false : true
    end

    def disabled?(page_id, id)
      command "disabled", page_id, id
    end

    def click_coordinates(x, y)
      command "click_coordinates", x, y
    end

    def evaluate(script, *args)
      command "evaluate", script, *args
    end

    def evaluate_async(script, wait_time, *args)
      command "evaluate_async", script, wait_time, *args
    end

    # FIXME: *args
    def execute(expression, *args)
      command "Runtime.evaluate", expression: expression
    end

    def within_frame(handle)
      if handle.is_a?(Capybara::Node::Base)
        command "push_frame", [handle.native.page_id, handle.native.id]
      else
        command "push_frame", handle
      end

      yield
    ensure
      command "pop_frame"
    end

    def switch_to_frame(handle)
      case handle
      when Capybara::Node::Base
        command "push_frame", [handle.native.page_id, handle.native.id]
      when :parent
        command "pop_frame"
      when :top
        command "pop_frame", true
      end
    end

    def window_handle
      command "window_handle"
    end

    def window_handles
      command "window_handles"
    end

    def switch_to_window(handle)
      command "switch_to_window", handle
    end

    def open_new_window
      command "open_new_window"
    end

    def close_window(handle)
      command "close_window", handle
    end

    def find_window_handle(locator)
      return locator if window_handles.include? locator

      handle = command "window_handle", locator
      raise NoSuchWindowError unless handle
      handle
    end

    def within_window(locator)
      original = window_handle
      handle = find_window_handle(locator)
      switch_to_window(handle)
      yield
    ensure
      switch_to_window(original)
    end

    def click(page_id, node, keys = [], offset = {})
      result = command "DOM.getContentQuads", nodeId: node["nodeId"]
      raise "Node is either not visible or not an HTMLElement" if result["quads"].size == 0

      # FIXME: Case when a few quad returned
      quads = result["quads"].map do |quad|
        [{x: quad[0], y: quad[1]},
         {x: quad[2], y: quad[3]},
         {x: quad[4], y: quad[5]},
         {x: quad[6], y: quad[7]}]
      end

      x, y = quads[0].inject([0, 0]) { |b, p| [b[0] + p[:x], b[1] + p[:y]] }
      x /= 4
      y /= 4


      # command "click", page_id, node, keys, offset
      command "Input.dispatchMouseEvent", type: "mouseMoved", x: x, y: y # hover then click?
      command "Input.dispatchMouseEvent", type: "mousePressed", button: "left", x: x, y: y, clickCount: 1
      command "Input.dispatchMouseEvent", type: "mouseReleased", button: "left", x: x, y: y, clickCount: 1
    end

    def right_click(page_id, id, keys = [], offset = {})
      command "right_click", page_id, id, keys, offset
    end

    def double_click(page_id, id, keys = [], offset = {})
      command "double_click", page_id, id, keys, offset
    end

    def hover(page_id, node)
      result = command "DOM.getContentQuads", nodeId: node["nodeId"]
      raise "Node is either not visible or not an HTMLElement" if result["quads"].size == 0

      # FIXME: Case when a few quad returned
      quads = result["quads"].map do |quad|
        [{x: quad[0], y: quad[1]},
         {x: quad[2], y: quad[3]},
         {x: quad[4], y: quad[5]},
         {x: quad[6], y: quad[7]}]
      end

      x, y = quads[0].inject([0, 0]) { |b, p| [b[0] + p[:x], b[1] + p[:y]] }
      x /= 4
      y /= 4

      command "Input.dispatchMouseEvent", type: "mouseMoved", x: x, y: y
      # command "hover", page_id, id
    end

    def drag(page_id, id, other_id)
      command "drag", page_id, id, other_id
    end

    def drag_by(page_id, id, x, y)
      command "drag_by", page_id, id, x, y
    end

    def select(page_id, id, value)
      command "select", page_id, id, value
    end

    def trigger(page_id, id, event)
      command "trigger", page_id, id, event.to_s
    end

    def reset
      # command "reset"
      restart
    end

    def scroll_to(left, top)
      command "scroll_to", left, top
    end

    def render(path, _options = {})
      # check_render_options!(options)
      # options[:full] = !!options[:full]
      data = Base64.decode64(render_base64)
      File.open(path.to_s, "w") { |f| f.write(data) }
    end

    def render_base64(format = "png", _options = {})
      # check_render_options!(options)
      # options[:full] = !!options[:full]
      command("Page.captureScreenshot", format: format)["data"]
    end

    def set_zoom_factor(zoom_factor)
      command "set_zoom_factor", zoom_factor
    end

    def set_paper_size(size)
      command "set_paper_size", size
    end

    def resize(width, height)
      command "resize", width, height
    end

    def send_keys(page_id, id, keys)
      command "send_keys", page_id, id, normalize_keys(keys)
    end

    def path(page_id, id)
      command "path", page_id, id
    end

    def network_traffic(type = nil)
    end

    def clear_network_traffic
      command("clear_network_traffic")
    end

    def set_proxy(ip, port, type, user, password)
      args = [ip, port, type]
      args << user if user
      args << password if password
      command("set_proxy", *args)
    end

    def equals(page_id, id, other_id)
      command("equals", page_id, id, other_id)
    end

    def get_headers
      command "get_headers"
    end

    def set_headers(headers)
      command "set_headers", headers
    end

    def add_headers(headers)
      command "add_headers", headers
    end

    def add_header(header, options = {})
      command "add_header", header, options
    end

    def response_headers
      command "response_headers"
    end

    def cookies
      Hash[command("cookies").map { |cookie| [cookie["name"], Cookie.new(cookie)] }]
    end

    def set_cookie(cookie)
      cookie[:expires] = cookie[:expires].to_i * 1000 if cookie[:expires]
      command "set_cookie", cookie
    end

    def remove_cookie(name)
      command "remove_cookie", name
    end

    def clear_cookies
      command "clear_cookies"
    end

    def cookies_enabled=(flag)
      command "cookies_enabled", !!flag
    end

    def set_http_auth(user, password)
      command "set_http_auth", user, password
    end

    def page_settings=(settings)
      command "set_page_settings", settings
    end

    def url_whitelist=(whitelist)
      command "set_url_whitelist", *whitelist
    end

    def url_blacklist=(blacklist)
      command "set_url_blacklist", *blacklist
    end

    def clear_memory_cache
      command "clear_memory_cache"
    end

    def go_back
      command "go_back"
    end

    def go_forward
      command "go_forward"
    end

    def refresh
      command "refresh"
    end

    def accept_confirm
      command "set_confirm_process", true
    end

    def dismiss_confirm
      command "set_confirm_process", false
    end

    def accept_prompt(response)
      command "set_prompt_response", response || false
    end

    def dismiss_prompt
      command "set_prompt_response", nil
    end

    def modal_message
      command "modal_message"
    end

    private

    def check_render_options!(options)
      return if !options[:full] || !options.key?(:selector)
      warn "Ignoring :selector in #render since :full => true was given at #{caller(1..1).first}"
      options.delete(:selector)
    end
  end
end