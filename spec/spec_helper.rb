require 'rubygems'

require 'bundler'
require 'spork'
require 'vcr'

Spork.prefork do
  require 'json_spec'
  require 'pp'
  require 'rspec'
  require 'webmock/rspec'

  APP_ROOT = File.expand_path('../../', __FILE__)
  ENV["BERKSHELF_PATH"] = File.join(APP_ROOT, "tmp", "berkshelf")
  ENV["BERKSHELF_CHEF_CONFIG"] = File.join(APP_ROOT, "tmp", "knife.rb")

  Dir[File.join(APP_ROOT, "spec/support/**/*.rb")].each {|f| require f}

  VCR.configure do |c|
    c.cassette_library_dir = File.join(File.dirname(__FILE__), 'fixtures', 'vcr_cassettes')
    c.hook_into :webmock
  end

  RSpec.configure do |config|
    config.include Berkshelf::RSpec::FileSystemMatchers
    config.include JsonSpec::Helpers
    config.include Berkshelf::RSpec::ChefAPI

    config.mock_with :rspec
    config.treat_symbols_as_metadata_keys_with_true_values = true
    config.filter_run focus: true
    config.run_all_when_everything_filtered = true

    config.around do |example|
      # Dynamically create cassettes based on the name of the example
      # being run. This creates a new cassette for every test.
      cur = example.metadata
      identifiers = [example.metadata[:description_args]]
      while cur = cur[:example_group] do
        identifiers << cur[:description_args]
      end

      VCR.use_cassette(identifiers.reverse.join(' ')) do
        example.run
      end
    end

    config.before(:each) do
      clean_tmp_path
      Berkshelf.cookbook_store = Berkshelf::CookbookStore.new(tmp_path.join("downloader_tmp"))
      Berkshelf.ui.mute!
    end

    config.after(:each) do
      Berkshelf.ui.unmute!
    end
  end

  def capture(stream)
    begin
      stream = stream.to_s
      eval "$#{stream} = StringIO.new"
      yield
      result = eval("$#{stream}").string
    ensure
      eval("$#{stream} = #{stream.upcase}")
    end

    result
  end

  def example_cookbook_from_path
    @example_cookbook_from_path ||= Berkshelf::Cookbook.new('example_cookbook', path: File.join(File.dirname(__FILE__), 'fixtures', 'cookbooks'))
  end

  def app_root_path
    Pathname.new(APP_ROOT)
  end

  def tmp_path
    app_root_path.join('spec/tmp')
  end

  def fixtures_path
    app_root_path.join('spec/fixtures')
  end

  def clean_tmp_path
    FileUtils.rm_rf(tmp_path)
    FileUtils.mkdir_p(tmp_path)
  end

  def git_origin_for(repo, options = {})
    "file://#{generate_fake_git_remote("git@github.com/RiotGames/#{repo}.git", options)}/.git"
  end

  def generate_fake_git_remote(uri, options = {})
    remote_bucket = Pathname.new(File.dirname(__FILE__)).join('tmp', 'remote_repos')
    FileUtils.mkdir_p(remote_bucket)

    repo_name = uri.to_s.split('/').last.split('.')
    name = if repo_name.last == 'git'
      repo_name.first
    else
      repo_name.last
    end
    name = 'rspec_cookbook' if name.nil? or name.empty?

    path = ''
    capture(:stdout) do
      Dir.chdir(remote_bucket) do
        Berkshelf::Cli.new.invoke(:cookbook, [name], skip_vagrant: true, force: true)
      end

      Dir.chdir(path = remote_bucket.join(name)) do
      run! "git config receive.denyCurrentBranch ignore"
      run! "echo '# a change!' >> content_file"
      run! "git add ."
      run "git commit -am 'A commit.'"
        options[:tags].each do |tag| 
          run! "echo '#{tag}' > content_file"
          run! "git add content_file"
          run "git commit -am '#{tag} content'"
          run "git tag '#{tag}' 2> /dev/null"
        end if options.has_key? :tags
      end
    end
    path
  end

  def git_sha_for_tag(repo, tag)
    Dir.chdir local_git_origin_path_for(repo) do
      run!("git show-ref '#{tag}'").chomp.split(/\s/).first
    end
  end

  def local_git_origin_path_for(repo)
    remote_repos_path = tmp_path.join('remote_repos')
    FileUtils.mkdir_p(remote_repos_path)
    remote_repos_path.join(repo)
  end

  def clone_target
    tmp_path.join('clone_targets')
  end

  def clone_target_for(repo)
    clone_target.join(repo)
  end

  def run!(cmd)
    out = `#{cmd}`
    raise "#{cmd} did not succeed:\n\tstatus: #{$?.exitstatus}\n\toutput: #{out}" unless $?.success?
    out
  end

  def run(cmd)
    `#{cmd}`
  end

  Berkshelf::RSpec::Knife.load_knife_config(File.join(APP_ROOT, 'spec/knife.rb'))
end

Spork.each_run do
  require 'berkshelf'
  require 'berkshelf/vagrant'

  module Berkshelf
    class GitLocation
      alias :real_clone :clone
      def clone
        fake_remote = generate_fake_git_remote(uri, tags: @branch ? [@branch] : [])
        tmp_clone = File.join(self.class.tmpdir, uri.gsub(/[\/:]/,'-'))
        @uri = "file://#{fake_remote}"
        real_clone
      end
    end
  end
end

