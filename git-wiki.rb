#!/usr/bin/ruby
require 'rack'
require 'grit'
require 'rdiscount'
require 'cgi'
require 'lib/tilt'

module GitWiki
  class << self
    attr_accessor :wiki_path, :root_page, :extension, :link_pattern
    attr_reader :wiki_name, :repository
    def wiki_path=(path)
      @wiki_name, @repository = File.basename(path), Grit::Repo.new(path)
    end

  end
end

GitWiki.wiki_path = Dir.pwd + '/uphvpn'
GitWiki.root_page = 'index'
GitWiki.extension = '.text'
GitWiki.link_pattern = /\[\[(.*?)\]\]/

class Page
  def self.find_all
    GitWiki.repository.tree.contents.select{|blob|
      blob.name =~ /#{GitWiki.extension}$/
    }.map{|blob| new(blob) }
  end

  def self.find_or_create(name, rev=nil)
    path = name + GitWiki.extension
    commit = GitWiki.repository.commit(rev || GitWiki.repository.head.commit.to_s)
    blob = commit.tree/path
    new(blob || Grit::Blob.create(GitWiki.repository, :name => path))
  end

  def self.wikify(content)
    content.gsub(GitWiki.link_pattern) {|match| link($1) }
  end

  def self.link(text)
    page = find_or_create(text.gsub(/[^\w\s]/, '').split.join('-').downcase)
    "<a class='page #{page.css_class}' href='#{page.url}'>#{text}</a>"
  end

  def initialize(blob)
    @blob = blob
  end

  def to_s; @blob.name.sub(/#{GitWiki.extension}$/, ''); end
  def url; to_s == GitWiki.root_page ? '/' : "/pages/#{to_s}"; end
  def edit_url; "/pages/#{to_s}/edit"; end
  def log_url; "/pages/#{to_s}/revisions/"; end
  def css_class; @blob.id ? 'existing' : 'new'; end
  def content; @blob.data; end
  def to_html; Page.wikify(RDiscount.new(content).to_html); end

  def log
    head = GitWiki.repository.head.name
    GitWiki.repository.log(head, @blob.name).map(&:to_hash)
  end

  def save!(data, msg)
    msg = "web commit: #{self}" if msg.to_s.empty?
    Dir.chdir(GitWiki.repository.working_dir) do
      File.open(@blob.name, 'w') {|f| f.puts(data.gsub("\r\n", "\n")) }
      GitWiki.repository.add(@blob.name)
      GitWiki.repository.commit_index(msg)
    end
  end
end

module GitWiki
  class App
    def initialize(app)
      @app = app
    end

    def call(env)
      case env['PATH_INFO']
      when '/'
        @page = Page.find_or_create(GitWiki.root_page)
        render_html 'show.haml'

      when '/pages/'
        @pages = Page.find_all
        render_html 'list.haml'

      when /\/pages\/(.+)\/revisions\/(.+)/
        @page = Page.find_or_create(name = $1, rev = $2)
        render_html 'show.haml'

      when /\/pages\/(.+)\/revisions\/?/
        @page = Page.find_or_create(name = $1)
        render_html 'log.haml'

      when /\/pages\/(.+)\/edit/
        @page = Page.find_or_create(name = $1)
        page_edit(env, @page)

      when /\/pages\/(.+)\/?/
        @page = Page.find_or_create(name = $1)
        render_html 'show.haml'

      else

        @app.call(env)
      end
    end

    def page_edit(env, page)
      case env['REQUEST_METHOD']
      when 'GET'
        render_html 'edit.haml'

      when 'POST'
        params = parse_post_params(env)
        if params['content']
          @page.save!(params['content'], params['msg'])
          [303, {'Location'=>@page.url}, []]
        end

      end || [404, {}, ['not found']]
    end

    def parse_post_params(env)
      Hash[ *env['rack.input'].read.split("&").map{|i|
        k, v = *i.split("=", 2); v == '' ? [k,nil] : [k, CGI.unescape(v)]
      }.flatten ]
    end

    def render_html(template_name)
      [200, {'Content-Type'=>'text/html'}, render_layout(template_name)]
    end

    def render_view(template_path)
      Tilt.new('views/' + template_path).render(self)
    end

    def render_layout(template_path, layout=true)
      Tilt.new('views/layout.haml').render(self){ render_view(template_path) }
    end

  end
end


# config.ru
app = Rack::Builder.new{
  use Rack::CommonLogger
  use Rack::Static, :urls => ['/css'], :root => 'public'
  use GitWiki::App
  run lambda{|env| [404, {}, ['not found']] }
}
Rack::Handler::Thin.run(app, :Port => 8085)
