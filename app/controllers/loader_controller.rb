class LoaderController < ApplicationController

  unloadable

  before_filter :find_project, :get_plugin_settings, only: [:analyze, :new, :create, :export]
  before_filter :authorize, except: :analyze
  before_filter :get_import_settings, only: [:analyze, :create]
  before_filter :get_export_settings, only: :export

  include Concerns::Import
  include Concerns::Export
  include QueriesHelper
  include SortHelper

  require 'zlib'
  require 'tempfile'
  require 'nokogiri'

  # This allows to update the existing task in Redmine from MS Project
  ActiveRecord::Base.lock_optimistically = false

  def new
  end

  def analyze
    begin
      xmlfile = params[:import][:xmlfile].try(:tempfile)
      if xmlfile
        @import = Import.new

        byte = xmlfile.getc
        xmlfile.rewind

        xmlfile = Zlib::GzipReader.new xmlfile unless byte == '<'[0]
        File.open(xmlfile, 'r') do |readxml|
          @import.hashed_name = (File.basename(xmlfile, File.extname(xmlfile)) + Time.now.to_s).hash.abs
          xmldoc = Nokogiri::XML::Document.parse(readxml).remove_namespaces!
          @import.tasks = get_tasks_from_xml(xmldoc)
        end

        subjects = @import.tasks.map(&:subject)
        @duplicates = subjects.select{ |subj| subjects.count(subj) > 1 }.uniq

        flash[:notice] = l(:tasks_read_successfully)
      else
        flash[:error] = l(:choose_file_warning)
      end
    rescue => error
      lines = error.message.split("\n")
      flash[:error] = l(:failed_read) + lines.to_s
    end
    redirect_to new_project_loader_path if flash[:error]
  end

  def create
    default_tracker_id = @settings[:import][:tracker_id]
    tasks_per_time = @settings[:import][:instant_import_tasks].to_i
    import_versions = @settings[:import][:sync_versions] == '1'
    tasks = params[:import][:tasks].select { |index, task_info| task_info[:import] == '1' }
    update_existing = params[:update_existing]

    flash[:error] = l(:choose_file_warning) unless tasks

    tasks_to_import = build_tasks_to_import tasks

    flash[:error] = l(:no_tasks_were_selected) if tasks_to_import.empty?

    user = User.current
    date = Date.today.strftime

    flash[:error] = l(:no_valid_default_tracker) unless default_tracker_id
    import_name = params[:hashed_name]

    if flash[:error]
      redirect_to new_project_loader_path # interrupt if any errors
      return
    end

    # Right, good to go! Do the import.
    begin
      milestones = tasks_to_import.select { |task| task.milestone == '1' }
      issues = tasks_to_import - milestones
      issues_info = tasks_to_import.map { |issue| {title: issue.subject, uid: issue.uid, outlinenumber: issue.outlinenumber, predecessors: issue.predecessors} }

      if tasks_to_import.size <= tasks_per_time
        uid_to_issue_id, outlinenumber_to_issue_id = Import.import_tasks(tasks_to_import, @project.id, user, nil, update_existing, import_versions)
        Import.map_subtasks_and_parents(issues_info, @project.id, nil, uid_to_issue_id, outlinenumber_to_issue_id)
        Import.map_versions_and_relations(milestones, issues, @project.id, nil, import_versions, uid_to_issue_id)

        flash[:notice] = l(:imported_successfully) + issues.count.to_s
        redirect_to project_issues_path(@project)
        return
      else
        tasks_to_import.each_slice(tasks_per_time).each do |batch|
          Import.delay(queue: import_name, priority: 1).import_tasks(batch, @project.id, user, import_name, update_existing, import_versions)
        end

        issues_info.each_slice(50).each do |batch|
          Import.delay(queue: import_name, priority: 3).map_subtasks_and_parents(batch, @project.id, import_name)
        end

        issues.each_slice(tasks_per_time).each do |batch|
          Import.delay(queue: import_name, priority: 4).map_versions_and_relations(milestones, batch, @project.id, import_name, import_versions)
        end

        Mailer.delay(queue: import_name, priority: 5).notify_about_import(user, @project, date, issues_info) # send notification that import finished

        Import.delay(queue: import_name, priority: 10).clean_up(import_name)

        flash[:notice] = t(:your_tasks_being_imported)
      end
    rescue => error
      flash[:error] = l(:unable_import) + error.to_s
      logger.debug "DEBUG: Unable to import tasks: #{ error }"
    end

    redirect_to new_project_loader_path
  end

  def export
    xml, name = generate_xml
    send_data xml, filename: name, disposition: :attachment
  end

  private

  def find_project
    @project = Project.find(params[:project_id])
  end

  def get_sorted_query
    retrieve_query
    sort_init(@query.sort_criteria.empty? ? [['id', 'desc']] : @query.sort_criteria)
    sort_update(@query.sortable_columns)
    @query.sort_criteria = sort_criteria.to_a
    @query_issues = @query.issues(include: [:assigned_to, :tracker, :priority, :fixed_version], order: sort_clause)
  end

  def get_plugin_settings
    @settings = Setting.plugin_redmine_loader
  end

  def get_import_settings
    @is_private_by_default = @settings[:import][:is_private_by_default] == '1'
    get_ignore_fields(:import)
  end

  def get_export_settings
    @export_versions = @settings[:export][:sync_versions] == '1'
    get_ignore_fields(:export)
  end

  def get_ignore_fields(way)
    @ignore_fields = { way.to_sym => @settings[way.to_sym][:ignore_fields].select { |attr, val| val == '1' }.keys }
  end
end
