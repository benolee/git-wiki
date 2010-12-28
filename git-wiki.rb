#!/usr/bin/ruby
require 'rack'
require 'rdiscount'
require 'cgi'

begin; require 'lib/tilt'; rescue LoadError
  require File.join(File.expand_path(File.dirname(__FILE__)), 'lib/tilt.rb')
end

Encoding.default_internal = 'UTF-8'
Encoding.default_external = 'UTF-8'

module GitWiki
  class << self
    attr_accessor :root_page, :extension, :link_pattern
    attr_accessor :git_dir, :net_port, :wiki_name
  end
end


raise ArgumentError if ARGV.size < 1

#
# git_dir bootstrap for a fresh wiki db (huge'n ugly)
#
git_dir = ARGV[0]
if not File.directory?(git_dir)
  puts "\n    GitWiki Error: find git-database!"
  puts "\n       '#{File.expand_path git_dir}' does NOT exist yet!"
  puts "\n       Want to create/prepare a git-wiki there?  (y/n)\n\n\n"

  # answer via stdin..
  if STDIN.getc.downcase == 'y'
    puts "  > making directory.."
    Dir.mkdir(git_dir)
    dir = "--git-dir='#{git_dir}'"

    puts "  > init repo.."
    `git #{dir}  init --bare`
    `rm #{git_dir}/hooks/*.sample` # purge hook samples

    puts "  > creates .gitignore blob.."
    # creates .gitignore blob
    blob = `echo "# git-ignore" | git #{dir} hash-object -w --stdin`.chomp

    puts "  > adds blob to the fresh tree.."
    `git #{dir} update-index --add --cacheinfo 100644 #{blob} .gitignore`

    puts "  > writes the tree object.."
    tree = `git #{dir} write-tree`.chomp

    puts "  > writes our first commit"
    env = 'GIT_AUTHOR_NAME=rb GIT_AUTHOR_EMAIL=meta.rb@gmail.com '
    env += 'GIT_COMMITTER_NAME=rb GIT_COMMITTER_EMAIL=meta.rb@gmail.com '
    commit_sha = `echo "new git-wiki repository" | #{env} git #{dir} commit-tree #{tree}`.chomp
    `echo #{commit_sha} > #{git_dir}/refs/heads/master`

    puts "  > DONE. new git-wiki 'database' is ready."
    puts "  > git_dir='#{File.expand_path git_dir}'"
    #puts "  >       the wiki's HEAD is at #{File.read(git_dir + '/refs/heads/master')}\n\n"
    puts "\n\n" + `git #{dir} log --stat`.chomp
  end
end


raise ArgumentError unless File.directory?(ARGV[0])

GitWiki.git_dir  = git_dir
GitWiki.net_port = ARGV[1] || 8085
GitWiki.root_page = 'index'
GitWiki.extension = '.text'
GitWiki.link_pattern = /\[\[(.*?)\]\]/

GitWiki.wiki_name = File.basename GitWiki.git_dir
GitWiki.wiki_name == '.git' && \
  GitWiki.wiki_name = File.basename(File.dirname(GitWiki.git_dir))
GitWiki.wiki_name = GitWiki.wiki_name.sub(/\.git$/,'')


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
            'files' => i[4..-2],
          }
        }
    end
  end

  def stage_tempfile_commit(data, msg, &block)
    t_blob, t_msg = *['blob','commit-msg'].map{|i| Tempfile.new(i+'-') }
    t_blob.write data.gsub("\r\n", "\n")
    t_msg.write msg.gsub("\r\n", "\n")
    [t_blob, t_msg].map(&:flush)
    res = Dir.chdir(GitWiki.git_dir){
      yield(t_blob, t_msg) if block_given?
    }
    [t_blob, t_msg].map(&:delete)
    res
  end

  def save!(data, msg)
    msg = "web commit: #{self}" if msg.to_s.empty?

    stage_tempfile_commit(data, msg) do |t_blob, t_msg|
      path = @name

      head = `cat refs/heads/master`.chomp
      tree = `git cat-file -p #{head} |head -c 45|cut -d' ' -f2`.chomp
      blob = `git hash-object -w #{t_blob.path}`.chomp

      `git read-tree #{head}`
      `git update-index --add --cacheinfo 100644 #{blob} #{path}`
      tree = `git write-tree`.chomp

      pcommit = "-p #{head}"
      git_env = ''
      commit_sha = `#{git_env} git commit-tree #{tree} #{pcommit} < #{t_msg.path}`.chomp
      `git update-ref refs/heads/master #{commit_sha}`

      commit_sha
    end
  end

  def git_env_base
    git_env  = 'GIT_AUTHOR_NAME=rb GIT_AUTHOR_EMAIL=meta.rb@gmail.com '
    git_env += 'GIT_COMMITTER_NAME=rb GIT_COMMITTER_EMAIL=meta.rb@gmail.com '
  end
end

require 'time'
def reltime(time, other=Time.now)
  s = (other - time)
  d, s = s.divmod(60*60*24)
  h, s = s.divmod(60*60)
  m, s = s.divmod(60)
  return "%d days" % d  if d > 1
  return "%d day" % d  if d > 0
  return "%d hours" % h  if h > 1
  return "%d hour" % h  if h > 0
  return "%d mins" % m  if m > 1
  return "%d min" % m  if m > 0
  return "%d secs" % s
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
        render_html 'show.erb'

      when '/pages/'
        @pages = Page.find_all
        render_html 'list.erb'

      when /\/pages\/(.+)\/revisions\/(.+)/
        @page = Page.find_or_create(name = $1, rev = $2)
        render_html 'show.erb'

      when /\/pages\/(.+)\/revisions\/?/
        @page = Page.find_or_create(name = $1)
        render_html 'log.erb'

      when /\/pages\/(.+)\/edit/
        @page = Page.find_or_create(name = $1)
        page_edit(env, @page)

      when /\/pages\/(.+)\/?/
        @page = Page.find_or_create(name = $1)
        render_html 'show.erb'

      else

        @app.call(env)
      end
    rescue => ex
      puts "\n\nGitWiki Exception-Rescue:\n"
      print "#{ex.inspect}\n\n" + ex.backtrace.join("\n") + "\n\n"
      [404,{},[]]
    end

    def page_edit(env, page)
      case env['REQUEST_METHOD']
      when 'GET'
        render_html 'edit.erb'

      when 'POST'
        params = request_params(env)
        if params['content']
          @page.save!(params['content'], params['msg'])
          [303, {'Location'=>@page.url}, []]
        end

      end || [404, {}, ['not found']]
    end

    def request_params(env)
      params = Rack::Request.new(env).params
      params.each{|k,v|
        v.encoding.to_s == 'ASCII-8BIT' && \
          params[k] = v.force_encoding('UTF-8')
      }; params
    end

    def render_html(template_name)
      [200, {'Content-Type'=>'text/html; charset=utf-8'}, render_layout(template_name)]
    end

    def render_view(template_path)
      Tilt.new('views/' + template_path).render(self)
    end

    def render_layout(template_path, layout=true)
      Tilt.new('views/layout.erb').render(self){ render_view(template_path) }
    end
  end
end


# config.ru
app = Rack::Builder.new{
  use Rack::CommonLogger
  use Rack::Static, :urls => ['/css', '/img', '/tmp'], :root => 'public'
  use GitWiki::App
  run lambda{|env| [404, {}, ['not found']] }
}.to_app
Rack::Handler::Thin.run(app, :Port => GitWiki.net_port)
