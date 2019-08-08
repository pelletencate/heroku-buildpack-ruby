# frozen_string_literal: true

# module LanguagePack::Test::Rails2
class LanguagePack::Rails2
  # sets up the profile.d script for this buildpack
  def setup_profiled
    super
    set_env_default 'RACK_ENV',  'test'
    set_env_default 'RAILS_ENV', 'test'
  end

  def default_env_vars
    {
      'RAILS_ENV' => 'test',
      'RACK_ENV' => 'test'
    }
  end

  def rake_env
    super.merge(default_env_vars)
  end

  def prepare_tests
    # need to clear db:create before db:schema:load_if_ruby gets called by super
    topic "Clearing #{db_test_tasks_to_clear.join(' ')} rake tasks"
    clear_db_test_tasks
    super
    topic 'Precompiling and caching assets'
    cache_and_run_assets_precompile_rake_task
  end

  def db_test_tasks_to_clear
    # db:test:purge is called by everything in the db:test namespace
    # db:create is called by :db:schema:load_if_ruby
    # db:structure:dump is not needed for tests, but breaks Rails 3.2 db:structure:load on Heroku
    ['db:test:purge', 'db:create', 'db:structure:dump']
  end

  # rails test runner + rspec depend on db:test:purge which drops/creates a db which doesn't work on Heroku's DB plans
  def clear_db_test_tasks
    FileUtils.mkdir_p 'lib/tasks'
    File.open('lib/tasks/heroku_clear_tasks.rake', 'w') do |file|
      file.puts '# rubocop:disable all'
      content = db_test_tasks_to_clear.map do |task_name|
        <<~FILE
          if Rake::Task.task_defined?('#{task_name}')
            Rake::Task['#{task_name}'].clear
            task '#{task_name}' do
            end
          end
        FILE
      end.join("\n")
      file.print content
      file.puts '# rubocop:enable all'
    end
  end

  private

  def db_prepare_test_rake_tasks
    schema_load    = rake.task('db:schema:load_if_ruby')
    structure_load = rake.task('db:structure:load_if_sql')
    db_migrate     = rake.task('db:migrate')

    return [] if db_migrate.not_defined?

    if schema_load.not_defined? && structure_load.not_defined?
      result = detect_schema_format
      case result.lines.last.chomp
      when 'ruby'
        schema_load    = rake.task('db:schema:load')
      when 'sql' # currently not a possible edge case, we think
        structure_load = rake.task('db:structure:load')
      else
        puts "Could not determine schema/structure from `ActiveRecord::Base.schema_format`:\n#{result}"
      end
    end

    [schema_load, structure_load, db_migrate]
  end

  def cache_and_run_assets_precompile_rake_task
    instrument 'rails5.run_assets_precompile_rake_task' do
      log('assets_precompile') do
        if Dir.glob('public/assets/{.sprockets-manifest-*.json,manifest-*.json}', File::FNM_DOTMATCH).any?
          puts 'Detected manifest file, assuming assets were compiled locally'
          return true
        end

        precompile = rake.task('assets:precompile')
        return true unless precompile.is_defined?

        topic('Preparing app for Rails asset pipeline')

        assets_folders.each { |a| @cache.load a }

        precompile.invoke(env: rake_env)

        if precompile.success?
          log 'assets_precompile', status: 'success'
          puts "Asset precompilation completed (#{format('%.2f', precompile.time)}s)"

          puts 'Cleaning assets'
          rake.task('assets:clean').invoke(env: rake_env)

          cleanup_assets_cache

          assets_folders.each { |a| @cache.store a }
        else
          precompile_fail(precompile.output)
        end
      end
    end
  end

  def assets_folders
    [
      node_modules_folder,
      public_assets_folder,
      public_packs_folder,
      public_packs_test_folder,
      default_assets_cache,
      webpacker_cache
    ]
  end

  def public_assets_folder
    'public/assets'
  end

  def public_packs_folder
    'public/packs'
  end

  def public_packs_test_folder
    'public/packs-test'
  end

  def assets_cache
    'tmp/cache/assets'
  end

  def webpacker_cache
    'tmp/cache/webpacker'
  end

  def node_modules_folder
    'node_modules'
  end

  def detect_schema_format
    run("rails runner 'puts ActiveRecord::Base.schema_format'", user_env: true)
  end
end
