#!/usr/bin/ruby
require 'rack'
require 'grit'
require 'rdiscount'
require 'cgi'
require 'lib/tilt'

module GitWiki
  class << self
    attr_accessor :root_page, :extension, :link_pattern
    attr_accessor :git_dir, :net_port, :wiki_name
  end
end

raise ArgumentError unless File.directory?(ARGV[0])
GitWiki.git_dir  = ARGV[0]
GitWiki.net_port = ARGV[1] || 8085
GitWiki.root_page = 'index'
GitWiki.extension = '.text'
GitWiki.link_pattern = /\[\[(.*?)\]\]/

GitWiki.wiki_name = File.basename GitWiki.git_dir
GitWiki.wiki_name == '.git' && \
  GitWiki.wiki_name = File.basename(File.dirname(GitWiki.git_dir))

class Page
  def self.find_all
    Dir.chdir(GitWiki.git_dir) do
      head = `cat refs/heads/master`.chomp
      tree = `git cat-file -p #{head} |head -c 45|cut -d' ' -f2`.chomp
      `git cat-file -p #{tree}`.split("\n")
        .map{|i|i.split(' ')}.select{|i| i.last =~ /#{GitWiki.extension}$/ }
        .map{|blob| new(blob[3], blob[2], tree) }
    end
  end

  def self.find_or_create(name, rev=nil)
    filename = name + GitWiki.extension
    Dir.chdir(GitWiki.git_dir) do
      rev = rev || `cat refs/heads/master`.chomp
      tree = `git cat-file -p $(git cat-file -p '#{rev.tr("'",'"')}' |head -c 45|cut -d' ' -f2)`.split("\n").map{|i|i.split(' ')}

      if blob = tree.select{|i| i.last == filename }.first
        new(filename, blob[2], tree)
      else
        new(filename, nil, tree)
      end
    end
  end

  def content
    Dir.chdir(GitWiki.git_dir){ `git cat-file blob #{@blob}` }
  end

  def self.wikify(content)
    content.gsub(GitWiki.link_pattern) {|match| link($1) }
  end

  def self.link(text)
    page = find_or_create(text.gsub(/[^\w\s]/, '').split.join('-').downcase)
    "<a class='page #{page.css_class}' href='#{page.url}'>#{text}</a>"
  end

  def initialize(name,blob,tree)
    @name,@blob,@tree = name,blob,tree
  end

  def to_s; @name.sub(/#{GitWiki.extension}$/, ''); end
  def url; to_s == GitWiki.root_page ? '/' : "/pages/#{to_s}"; end
  def edit_url; "/pages/#{to_s}/edit"; end
  def log_url; "/pages/#{to_s}/revisions/"; end
  def css_class; @blob ? 'existing' : 'new'; end
  def to_html; Page.wikify(RDiscount.new(content).to_html); end

  def log
    Dir.chdir(GitWiki.git_dir) do
      filename = @name
      head = `cat refs/heads/master`.chomp

      `git log --stat #{head} -- #{filename}`
        .scan(/commit (.+)\nAuthor: (.+)\nDate: (.+)\n\n(.+)\n\n(.+)\n(.+)\n\n/)
        .map{|i|
          {
            'id' => i[0], 'author' => i[1],
            'committed_date' => i[2].strip,
            'message' => i[3].strip, 'files_summary' => i[-1],
            #'files' => i[4..-2],
          }
        }
    end
  end

  def save!(data, msg)
    msg = "web commit: #{self}" if msg.to_s.empty?
    Dir.chdir(GitWiki.git_dir) do
      path = @name

      File.open(path, 'w') {|f| f.puts(data.gsub("\r\n", "\n")) }

      head = `cat refs/heads/master`.chomp
      tree = `git cat-file -p #{head} |head -c 45|cut -d' ' -f2`.chomp
      blob = `git hash-object -w #{path}`.chomp

      `git read-tree #{head}`
      `git update-index --add --cacheinfo 100644 #{blob} #{path}`
      tree = `git write-tree`.chomp

      pcommit = "-p #{head}"
      commit_sha = `echo "update #{@name}" | git commit-tree #{tree} #{pcommit}`.chomp
      `git update-ref refs/heads/master #{commit_sha}`
    end
  end
end

require 'time'
def reltime(time, other=Time.now)
  s = (other - time)
  d, s = s.divmod(60*60*24)
  h, s = s.divmod(60*60)
  m, s = s.divmod(60)
  return "%dd" % d  if d > 0
  return "%dh" % h  if h > 0
  return "%dm" % m  if m > 0
  return "%ds" % s
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
        render_html 'list.erb'

      when /\/pages\/(.+)\/revisions\/(.+)/
        @page = Page.find_or_create(name = $1, rev = $2)
        render_html 'show.haml'

      when /\/pages\/(.+)\/revisions\/?/
        @page = Page.find_or_create(name = $1)
        render_html 'log.erb'

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
Rack::Handler::Thin.run(app, :Port => GitWiki.net_port)
