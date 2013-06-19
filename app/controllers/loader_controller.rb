class LoaderController < ApplicationController

  unloadable

  before_filter :find_project, :only => [:analyze, :new, :create, :export]
  before_filter :authorize, :except => :analyze

  include QueriesHelper
  include SortHelper

  require 'zlib'
  require 'ostruct'
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
        @import = TaskImport.new

        byte = xmlfile.getc
        xmlfile.rewind

        xmlfile = Zlib::GzipReader.new xmlfile unless byte == '<'[0]
        File.open(xmlfile, 'r') do |readxml|
          xmldoc = Nokogiri::XML::Document.parse(readxml).remove_namespaces!
          @import.tasks, @import.new_categories = get_tasks_from_xml(xmldoc)
        end

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
    tasks = params[:import][:tasks].select { |index, task_info| task_info[:import] == '1' }

    flash[:error] = l(:choose_file_warning) unless tasks

    tasks_to_import = Loader.build_tasks_to_import tasks

    flash[:error] = l(:no_tasks_were_selected) if tasks_to_import.empty?

    default_tracker_id = Setting.plugin_redmine_loader['tracker_id']
    user = User.current
    date = Date.today.strftime

    flash[:error] = l(:no_valid_default_tracker) unless default_tracker_id

    if flash[:error]
      redirect_to new_project_loader_path # interrupt if any errors
      return
    end

    # Right, good to go! Do the import.
    begin
      if tasks_to_import.size <= Setting.plugin_redmine_loader['instant_import_tasks'].to_i
        Loader.import_tasks(tasks_to_import, @project, user)

        flash[:notice] = l(:imported_successfully) + tasks_to_import.size.to_s
        redirect_to project_issues_path(@project)
        return
      else
        # slice issues array to few batches, because psych can't process array bigger than 65536
        tasks_to_import.each_slice(30).to_a.each do |batch|
          Loader.delay.import_tasks(batch, @project, user)
        end
        issues_info = tasks_to_import.map { |issue| {:title => issue.title} }
        Mailer.delay.notify_about_import(user, @project, date, issues_info) # send notification that import finished
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
    send_data xml, :filename => name, :disposition => 'attachment'
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
    @query_issues = @query.issues(:include => [:assigned_to, :tracker, :priority, :category, :fixed_version], :order => sort_clause)
  end

  def generate_xml
    @id = 0
    request_from = Rails.application.routes.recognize_path(request.referrer)
    get_sorted_query unless request_from[:controller] =~ /loader/

    export = Nokogiri::XML::Builder.new(:encoding => 'UTF-8') do |xml|
      @used_issues = {}
      xml.Project {
        xml.Tasks {
          xml.Task {
            xml.UID "0"
            xml.ID "0"
            xml.ConstraintType "0"
            xml.OutlineNumber "0"
            xml.OutlineLevel "0"
            xml.Name @project.name
            xml.Type "1"
            xml.CreateDate @project.created_on.to_s(:ms_xml)
          }

          if @query
            determine_nesting @query_issues
            @nested_issues.each { |struct| write_task(xml, struct) }
            Version.where(:id => @query_issues.map(&:fixed_version_id).uniq).each { |version| write_version(xml, version) }
          else
            @project.versions.each { |version| write_version(xml, version) }
            issues = @project.issues.visible
            determine_nesting(issues)
            @nested_issues.each { |issue| write_task(xml, issue) }
          end

        }
        xml.Resources {
          xml.Resource {
            xml.UID "0"
            xml.ID "0"
            xml.Type "1"
            xml.IsNull "0"
          }
          resources = @project.members
          resources.each do |resource|
            xml.Resource {
              xml.UID resource.user_id
              xml.ID resource.id
              xml.Name resource.user.login
              xml.Type "1"
              xml.IsNull "0"
              xml.MaxUnits "1.0"
            }
          end
        }
        xml.Assignments {
          source_issues = @query ? @query_issues : @project.issues
          source_issues.each do |issue|
            xml.Assignment {
              xml.UID issue.id
              xml.TaskUID issue.id
              xml.ResourceUID issue.assigned_to_id
              xml.PercentWorkComplete issue.done_ratio
              xml.Units "1"
            }
          end
        }
      }
    end

    #To save the created xml with the name of the project
    filename = "#{@project.name}-#{Time.now.strftime("%Y-%m-%d-%H-%M")}.xml"
    return export.to_xml, filename
  end

  def determine_nesting(issues)
    @nested_issues = []
    grouped = issues.group_by(&:level).sort_by{ |key| key }
    grouped.each do |level, grouped_issues|
      grouped_issues.each_with_index do |issue, index|
        struct = Task.new
        struct.issue = issue
        if child = issue.child?
          parent = issue.parent
          parent_outlinenumber = @nested_issues.detect{ |struct| struct.issue == parent }.try(:outlinenumber)
        end
        struct.outlinenumber = child ? parent_outlinenumber.to_s + '.' + (index + 1).to_s : issues.index(issue)
        struct.outlinelevel = issue.level + 1
        @nested_issues << struct
      end
    end
    return @nested_issues
  end

  def get_priority_value(priority_name)
    value = case priority_name
            when 'Minimal' then 100
            when 'Low' then 300
            when 'Normal' then 500
            when 'High' then 700
            when 'Immediate' then 900
            end
    return value
  end

  def write_task(xml, struct, due_date=nil, under_version=false)
    return if @used_issues.has_key?(struct.issue.id)
    xml.Task {
      @used_issues[struct.issue.id] = true
      xml.UID(struct.issue.id)
      xml.ID(struct.tid)
      xml.Name(struct.issue.subject)
      xml.Notes(struct.issue.description)
      xml.CreateDate(struct.issue.created_on.to_s(:ms_xml))
      xml.Priority(get_priority_value(struct.issue.priority.name))
      xml.Start(struct.issue.try(:start_date).try(:to_time).try(:to_s, :ms_xml))
      xml.Finish(struct.issue.try(:due_date).try(:to_time).try(:to_s, :ms_xml))
      xml.FixedCostAccrual "3"
      xml.ConstraintType "4"
      xml.ConstraintDate(struct.issue.try(:start_date).try(:to_time).try(:to_s, :ms_xml))
      #If the issue is parent: summary, critical and rollup = 1, if not = 0
      parent = Issue.find(struct.issue.id).leaf? ? 0 : 1
      xml.Summary(parent)
      xml.Critical(parent)
      xml.Rollup(parent)
      xml.Type(parent)

      xml.PredecessorLink {
        xml.PredecessorUID struct.issue.fixed_version_id
      }

      xml.WBS(struct.outlinenumber)
      xml.OutlineNumber(struct.outlinenumber)
      xml.OutlineLevel(struct.outlinelevel)
    }
  end

  def write_version(xml, version)
    xml.Task {
      @id += 1
      xml.UID(version.id)
      xml.ID(@id)
      xml.Name(version.name)
      xml.Notes(version.description)
      xml.CreateDate(version.created_on.to_s(:ms_xml))
      if version.effective_date
        xml.Start(version.effective_date.to_time.to_s(:ms_xml))
        xml.Finish(version.effective_date.to_time.to_s(:ms_xml))
      end
      xml.Milestone "1"
      xml.FixedCostAccrual("3")
      xml.ConstraintType("4")
      xml.ConstraintDate(version.try(:effective_date).try(:to_time).try(:to_s, :ms_xml))
      xml.Summary("1")
      xml.Critical("1")
      xml.Rollup("1")
      xml.Type("1")
      # Removed for now causes too many circular references
      #issues = @project.issues.find(:all, :conditions => ["fixed_version_id = ?", version.id], :order => "parent_id, start_date, id")
      #issues.each do |issue|
      #  xml.PredecessorLink { xml.PredecessorUID(issue.id) }
      #end
      xml.WBS(@id)
      xml.OutlineNumber(@id)
      xml.OutlineLevel("1")
    }
  end

  def get_tasks_from_xml(doc)

    # Extract details of every task into a flat array

    tasks = []
    @unprocessed_task_ids = []

    logger.debug "DEBUG: BEGIN get_tasks_from_xml"

    tracker_alias = Setting.plugin_redmine_loader['tracker_alias']
    tracker_field_id = nil

    doc.xpath("Project/ExtendedAttributes/ExtendedAttribute[Alias='#{tracker_alias}']/FieldID").each do |ext_attr|
      tracker_field_id = ext_attr.text.to_i
    end

    doc.xpath('Project/Tasks/Task').each do |task|
      begin
        logger.debug "Project/Tasks/Task found"
        struct = Task.new
        struct.level = task.at('OutlineLevel').try(:text).try(:to_i)
        struct.outlinenumber = task.at('OutlineNumber').try(:text).try(:strip)

        auxString = struct.try(:outlinenumber)

        index = auxString.rindex('.')
        if index
          index -= 1
          struct.outnum = auxString[0..index]
        end
        struct.tid = task.at('ID').try(:text).try(:to_i)
        struct.uid = task.at('UID').try(:text).try(:to_i)
        struct.title = task.at('Name').try(:text).try(:strip)
        struct.start = task.at('Start').try(:text).try{|t| t.split("T")[0]}
        struct.finish = task.at('Finish').try(:text).try{|t| t.split("T")[0]}
        struct.priority = task.at('Priority').try(:text)

        task.xpath("ExtendedAttribute[FieldID='#{tracker_field_id}']/Value").each do |tracker_value|
          struct.tracker_name = tracker_value.text
        end

        struct.milestone = task.at('Milestone').try(:text).try(:to_i)
        struct.percentcomplete = task.at('PercentComplete').try(:text).try(:to_i)
        struct.notes = task.at('Notes').try(:text).try(:strip)
        struct.predecessors = []
        struct.delays = []
        task.xpath('PredecessorLink').each do |predecessor|
          struct.predecessors.push(predecessor.at('PredecessorUID').try(:text).try(:to_i))
          struct.delays.push(predecessor.at('LinkLag').try(:text).try(:to_i))
        end

      tasks.push(struct)

      rescue => error
        # Ignore errors; they tend to indicate malformed tasks, or at least,
        # XML file task entries that we do not understand.
        logger.debug "DEBUG: Unrecovered error getting tasks: #{error}"
        @unprocessed_task_ids.push task.at('ID').try(:text).try(:to_i)
      end
    end

    tasks = tasks.drop(1).compact.uniq.sort_by(&:uid)

    # Step through the sorted tasks. Each time we find one where the
    # *next* task has an outline level greater than the current task,
    # then the current task MUST be a summary. Record its name and
    # blank out the task from the array. Otherwise, use whatever
    # summary name was most recently found (if any) as a name prefix.

    all_categories = []
    category = ''

    tasks.each_with_index do |task, index|
      next_task = tasks[index + 1]

      # Instead of deleting the sumary tasks I only delete the task 0 (the project)

      #if ( next_task and next_task.level > task.level )
      #  category = task.title.strip.gsub(/:$/, '') unless task.title.nil? # Kill any trailing :'s which are common in some project files
      #  all_categories.push(category) # Keep track of all categories so we know which ones might need to be added
        #tasks[ index ] = "Prueba"
      if task.level == 0
        category = task.try(:title).try(:strip).try(:gsub, /:$/, '') # Kill any trailing :'s which are common in some project files
        all_categories.push(category) # Keep track of all categories so we know which ones might need to be added
        task = nil
      else
        task.category = category
      end
    end

    set_assignment_to_task(doc, tasks)
    logger.debug "DEBUG: Tasks: #{tasks.inspect}"
    all_categories = all_categories.uniq
    logger.debug "DEBUG: END get_tasks_from_xml"
    return tasks, all_categories
  end

  NOT_USER_ASSIGNED = -65535

  def set_assignment_to_task(doc, tasks)
    uid_tasks = tasks.map(&:uid)
    resource_by_user = get_bind_resource_users(doc)
    doc.xpath('Project/Assignments/Assignment').each do |as|
      task_uid = as.at('TaskUID').text.to_i
      task = tasks.detect { |task| task.uid == task_uid }
      next unless task
      resource_id = as.at('ResourceUID').text.to_i
      next if resource_id == NOT_USER_ASSIGNED
      task.assigned_to = resource_by_user[resource_id]
    end
  end

  def get_bind_resource_users(doc)
    resources = get_resources(doc)
    users_list = @project.assignable_users
    resource_by_user = {}
    resources.each do |uid, name|
      user_found = users_list.detect { |user| user.login == name }
      next unless user_found
      resource_by_user[uid] = user_found.id
    end
    return resource_by_user
  end

  def get_resources(doc)
    resources = {}
    doc.xpath('Project/Resources/Resource').each do |resource|
      resource_uid = resource.at('UID').try(:text).try(:to_i)
      resource_name_element = resource.at('Name').try(:text)
      next unless resource_name_element
      resources[resource_uid] = resource_name_element
    end
    return resources
  end
end
