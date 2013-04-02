class TaskImport
  @tasks = []
  @project_id = nil
  @new_categories = []

  attr_accessor :tasks, :project_id, :new_categories
end

class LoaderController < ApplicationController

  unloadable

  before_filter :find_project, :authorize, :only => [:new, :create]

  require 'zlib'
  require 'ostruct'
  require 'tempfile'
  require 'rexml/document'
  require 'builder/xmlmarkup'

  # This allows to update the existing task in Redmine from MS Project
  ActiveRecord::Base.lock_optimistically = false

  # Set up the import view. If there is no task data, this will consist of
  # a file entry field and nothing else. If there is parsed file data (a
  # preliminary task list), then this is included too.

  def new
  end

  # Take the task data from the 'new' view form and 'create' an "import
  # session"; that is, create real Task objects based on the task list and
  # add them to the database, wrapped in a single transaction so that the
  # whole operation can be unwound in case of error.

  def create

    # Set up a new TaskImport session object and read the XML file details

    xmlfile = params[:import][:xmlfile].try(:tempfile)
    @import = TaskImport.new

    if xmlfile

      # The user selected a file to upload, so process it

      begin

        # We assume XML files always begin with "<" in the first byte and
        # if that's missing then it's GZip compressed. That's true in the
        # limited case of project files.

        byte = xmlfile.getc
        xmlfile.rewind

        xmlfile = Zlib::GzipReader.new xmlfile unless byte == '<'[0]
        readxml = File.open(xmlfile, 'r')
        xmldoc = REXML::Document.new(readxml)
        @import.tasks, @import.new_categories = get_tasks_from_xml(xmldoc)

        if @import.tasks.any?
          flash[:notice] = l(:tasks_read_successfully)
        else
          flash[:error] = l(:no_tasks_found)
        end
        readxml.close

      rescue => error

        # REXML errors can be huge, including a full backtrace. It can cause
        # session cookie overflow and we don't want the user to see it. Cut
        # the message off at the first newline.

        lines = error.message.split("\n")
        flash[:error] = l(:failed_read) + lines.to_s
      end

      render :action => :new
      flash.delete :error
      flash.delete :notice

    else

      # No file was specified. If there are no tasks either, complain.

      tasks = params[:import][:tasks]

      if tasks.nil?
        flash[:error] = l(:choose_file_warning)
        render :action => :new
        flash.delete :error
        return
      end

      # Compile the form submission's task list into something that the
      # TaskImport object understands.
      #
      # Since we'll rebuild the tasks array inside @import, we can render the
      # 'new' view again and have the same task list presented to the user in
      # case of error.

      @import.tasks = []
      @import.new_categories = []
      to_import = []

      # Due to the way the form is constructed, 'task' will be a 2-element
      # array where the first element contains a string version of the index
      # at which we should store the entry and the second element contains
      # the hash describing the task itself.

      tasks.each do |taskinfo|
        index = taskinfo[0].to_i
        task = taskinfo[1]
        struct = OpenStruct.new

        struct.uid = task[:uid]
        struct.title = task[:title]
        struct.level = task[:level]
        struct.outlinenumber = task[:outlinenumber]
        struct.outnum = task[:outnum]
        struct.code = task[:code]
        struct.duration = task[:duration]
        struct.start = task[:start]
        struct.finish = task[:finish]
        struct.percentcomplete = task[:percentcomplete]
        struct.predecessors = task[:predecessors].split(', ')
        struct.delays = task[:delays].split(', ')
        struct.category = task[:category]
        struct.assigned_to = task[:assigned_to]
        struct.parent_id = task[:parent_id]
        struct.notes = task[:notes]
        struct.milestone = task[:milestone]
        struct.tracker_name = task[:tracker_name]
        @import.tasks[index] = struct
        to_import[index] = struct if task[:import] == '1'
      end

      to_import.compact!

      # The "import" button in the form causes token "import_selected" to be
      # set in the params hash. The "analyse" button causes nothing to be set.
      # If the user has clicked on the "analyse" button but we've reached this
      # point, then they didn't choose a new file yet *did* have a task list
      # available. That's strange, so raise an error.
      #
      # On the other hand, if the 'import' button *was* used but no tasks were
      # selected for error, raise a different error.

      if params[:import].nil?
        flash[:error] = l(:choose_file_warning)
      elsif to_import.empty?
        flash[:error] = l(:no_tasks_were_selected)
      end

      # Get defaults to use for all tasks - sure there is a nicer ruby way, but this works
      #
      # Tracker
      default_tracker_name = Setting.plugin_redmine_loader['tracker']
      default_tracker = Tracker.find(:first, :conditions => ["name = ?", default_tracker_name])
      default_tracker_id = default_tracker.id

      flash[:error] = l(:no_valid_default_tracker) unless default_tracker_id

      # Bail out if we have errors to report.
      unless flash[:error].nil?
        render :action => :new
        flash.delete :error
        return
      end

      # We're going to keep track of new issue ID's to make dependencies work later
      uidToIssueIdMap = {}
      # keep track of new Version ID's
      uidToVersionIdMap = {}
      # keep track of the outlineNumbers to set the parent_id
      outlineNumberToIssueIDMap = {}

      # Right, good to go! Do the import.
      begin
        Issue.transaction do
          to_import.each do |source_issue|

            # We comment those lines becouse they are not necesary now.
            # Add the category entry if necessary
            #category_entry = IssueCategory.find :first, :conditions => { :project_id => @project.id, :name => source_issue.category }
            logger.debug "DEBUG: Issue to be imported: #{source_issue.inspect}"
            if source_issue.category.present?
              logger.debug "DEBUG: Search category id by name: #{source_issue.category}"
              category_entry = IssueCategory.find(:first, :conditions => { :project_id => @project.id, :name => source_issue.category })
              logger.debug "DEBUG: Category found: #{category_entry.inspect}"
            end

            if source_issue.tracker_name.present?
              logger.debug "DEBUG: Search tracker id by name: #{source_issue.tracker_name}"
              final_tracker = Tracker.find(:first, :conditions => ["name = ?", source_issue.tracker_name])
              logger.debug "DEBUG: Tracker found: #{final_tracker.inspect}"
            else
              final_tracker = default_tracker
            end

            if source_issue.milestone.to_i == 0
              destination_issue = Issue.find(:first, :conditions => ["project_id = ? AND id = ?", @project.id, source_issue.uid]) || Issue.new
              destination_issue.tracker_id = final_tracker.id
              destination_issue.category_id = category_entry.try(:id)
              destination_issue.subject = source_issue.title.slice(0, 255) # Max length of this field is 255
              destination_issue.estimated_hours = source_issue.duration
              destination_issue.project_id = @project.id
              destination_issue.author_id = User.current.id
              destination_issue.lock_version = 0
              destination_issue.done_ratio = source_issue.try(:percentcomplete)
              destination_issue.start_date = source_issue.try(:start)
              destination_issue.due_date = source_issue.try(:finish)
              if destination_issue.due_date.nil? && destination_issue.start_date
                destination_issue.due_date = (Date.parse(source_issue.start, false) + ((source_issue.duration.to_f/40.0)*7.0).to_i).to_s
              end
              destination_issue.description = source_issue.try(:notes)

              logger.debug "DEBUG: Assigned_to field: #{source_issue.assigned_to}"

              destination_issue.assigned_to_id = source_issue.assigned_to if source_issue.assigned_to
              destination_issue.try(:save!)

              logger.debug "DEBUG: Issue #{destination_issue.subject} imported"
              # Now that we know this issue's Redmine issue ID, save it off for later
              uidToIssueIdMap[ source_issue.uid ] = destination_issue.id
              #Save the Issue's ID with the outlineNumber as an index, to set the parent_id later
              outlineNumberToIssueIDMap[source_issue.outlinenumber] = destination_issue.id
            else
              #If the issue is a milestone we save it as a Redmine Version
              version_record = Version.find(:first, :conditions => ["project_id = ? AND id = ?", @project.id, source_issue.uid]) || Version.new
              version_record.name = source_issue.title.slice(0, 59)#maximum is 60 characters
              version_record.description = source_issue.try(:notes)
              version_record.effective_date = source_issue.start
              version_record.project_id = @project.id
              version_record.try(:save!)
              # Store the version_record.id  to assign the issues to the version later
              uidToVersionIdMap[ source_issue.uid ] = version_record.id
            end
          end

          flash[:notice] = l(:imported_successfully) + to_import.length.to_s
        end

        # Set the parent_id. We use the outnum of the issue (the outlineNumber without the last .#).
        # This outnum is the same as the parent's outlineNumber, so we can use it as the index of the
        # outlineNumberToIssueIDMap to get the parent's ID
        Issue.transaction do
          to_import.each do |source_issue|
            destination_issue = Issue.find(:first, :conditions => ["project_id = ? AND id = ?", @project.id, uidToIssueIdMap[source_issue.uid]])
            destination_issue.parent_issue_id = outlineNumberToIssueIDMap[source_issue.outnum] if destination_issue
            destination_issue.try(:save!)
          end
        end

        # Delete all the relations off the issues that we are going to import. If they continue existing we are going to create them. If not they must be deleted.
        to_import.each do |source_issue|
          IssueRelation.delete_all(["issue_to_id = ?", source_issue.uid])
        end

        # Handle all the dependencies being careful if the parent doesn't exist
        IssueRelation.transaction do
          to_import.each do |source_issue|
            delaynumber = 0
            source_issue.predecessors.each do |parent_uid|
              # Parent is being imported also. Go ahead and add the association
              if uidToIssueIdMap.has_key?(parent_uid)
                # If the issue is not a milestone we have to create the issue relation
                if source_issue.milestone.to_i == 0
                  relation_record = IssueRelation.new do |i|
                    i.issue_from_id = uidToIssueIdMap[parent_uid]
                    i.issue_to_id = uidToIssueIdMap[source_issue.uid]
                    i.relation_type = 'precedes'
                    # Set the delay of the relation if it exists.
                    if source_issue.try { |e| e.delays[delaynumber].to_i > 0 }
                      i.delay = (source_issue.delays[delaynumber].to_i)/4800
                      delaynumber = delaynumber + 1
                    end
                  end
                  relation_record.save!
                else
                  # If the issue is a milestone we have to assign the predecessor to the version
                  destination_issue = Issue.find(:first, :conditions => ["project_id = ? AND id = ?", @project.id, uidToIssueIdMap[parent_uid]])
                  destination_issue.fixed_version_id = uidToVersionIdMap[source_issue.uid]
                  destination_issue.save!
                end
              end
            end
          end
        end
        redirect_to "/projects/#{@project.identifier}/issues"

        rescue => error
        flash[:error] = l(:unable_import) + error.to_s
        logger.debug "DEBUG: Unable to import tasks: #{ error }"
        render :action => :new
      end
    end
  end

  def export
    find_project
    xml, name = generate_xml
    hijack_response(xml, name)
  end

  private

  def find_project
    @project = Project.find(params[:project_id])
  end

  def generate_xml
    xml = Builder::XmlMarkup.new(:target => out_string = "", :indent => 2)
    issues = []
    @used_issues = {}
    xml.Project do
      xml.Tasks do
        xml.Task do
          xml.UID("0")
          xml.ID("0")
          xml.Name(@project.name)
          xml.Type("1")
          xml.CreateDate(@project.created_on.to_s(:ms_xml))
          xml.ConstraintType("0")
        end
        @id = 0
        # adding version sorting
        versions = @project.versions.find(:all, :order => "effective_date ASC, id")
        versions.each do |version|
          xml.Task do
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
            xml.FixedCostAccrual("3")
            xml.ConstraintType("4")
            xml.ConstraintDate(version.effective_date.to_time.to_s(:ms_xml)) if version.effective_date
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
            xml.OutlineLevel(1)
          end
          issues = @project.issues.find(:all, :conditions => ["fixed_version_id=?",version.id], :order => "parent_id, start_date, id" )
          issues.each { |issue| write_task(xml, issue, version.effective_date, true) }
        end
        issues = @project.issues.find(:all, :order => "parent_id, start_date, id", :conditions => ["fixed_version_id = ?", nil])
        issues.each { |issue| write_task(xml, issue, nil, false) }
      end
      xml.Resources do
        xml.Resource do
          xml.UID("0")
          xml.ID("0")
          xml.Type("1")
          xml.IsNull("0")
        end
        resources = @project.members.find(:all)
        resources.each do |resource|
          xml.Resource do
            xml.UID(resource.user_id)
            xml.ID(resource.id)
            xml.Name(resource.name)
            xml.Type("1")
            xml.IsNull("0")
          end
        end
      end
      # We do not assign the issue to any resource, just set the done_ratio
      xml.Assignments do
        @project.issues.each do |issue|
          xml.Assignment do
            xml.UID(issue.id)
            xml.TaskUID(issue.id)
            xml.ResourceUID(issue.assigned_to_id)
            xml.PercentWorkComplete(issue.done_ratio)
          end
        end
      end
    end

    #To save the created xml with the name of the project
    projectname = @project.name + ".xml"
    return out_string, projectname
  end

  def write_task(xml, issue, due_date, under_version)

    return if @used_issues.has_key?(issue.id)
    xml.Task do
      @id += 1
      @used_issues[issue.id] = true
      xml.UID(issue.id)
      xml.ID(@id)
      xml.Name(issue.subject)
      xml.Notes(issue.description)
      xml.CreateDate(issue.created_on.to_s(:ms_xml))
      xml.Priority(issue.priority_id)
      xml.Start(issue.start_date.to_time.to_s(:ms_xml)) if issue.start_date
      if issue.due_date
        xml.Finish(issue.due_date.to_time.to_s(:ms_xml))
      elsif due_date
        xml.Finish(due_date.to_time.to_s(:ms_xml))
      end
      xml.FixedCostAccrual("3")
      xml.ConstraintType("4")
      xml.ConstraintDate(issue.start_date.to_time.to_s(:ms_xml)) if issue.start_date
      #If the issue is parent: summary, critical and rollup = 1, if not = 0
      if is_parent(issue.id) == 1
        xml.Summary("1")
        xml.Critical("1")
        xml.Rollup("1")
        xml.Type("1")
      else
        xml.Summary("0")
        xml.Critical("0")
        xml.Rollup("0")
        xml.Type("0")
      end

      #xml.PredecessorLink do
      #  IssueRelation.find(:all, :include => [:issue_from, :issue_to], :conditions => ["issue_to_id = ? AND relation_type = 'precedes'", issue.id]).select do |ir|
      #    xml.PredecessorUID(ir.issue_from_id)
      #  end
      #end

      #If it is a main task => WBS = id, outlineNumber = id, outlinelevel = 1
      #If not, we have to get the outlinelevel

      outlinelevel = under_version ? 2 : 1
      while issue.parent_id != nil
        issue = @project.issues.find(:first, :conditions => ["id = ?", issue.parent_id])
        outlinelevel += 1
      end
      xml.WBS(@id)
      xml.OutlineNumber(@id)
      xml.OutlineLevel(outlinelevel)
    end
    issues = []
    issues = @project.issues.find(:all, :order => "start_date, id", :conditions => ["parent_id=?", issue.id])
    issues.each { |sub_issue| write_task(xml, sub_issue, due_date, under_version) }
  end

  def hijack_response(out_data, projectname)
    send_data(out_data, :type => "text/xml", :filename => projectname)
  end

  # Look if the issue is parent of another issue or not
  def is_parent(issue_id)
    return Issue.find(:first, :conditions => ["parent_id = ?", issue_id])
  end

  # Obtain a task list from the given parsed XML data (a REXML document).

  def get_tasks_from_xml(doc)

    # Extract details of every task into a flat array
    tasks = []

    logger.debug "DEBUG: BEGIN get_tasks_from_xml"

    tracker_alias = Setting.plugin_redmine_loader['tracker_alias']
    tracker_field_id = nil

    doc.each_element "Project/ExtendedAttributes/ExtendedAttribute[Alias='#{tracker_alias}']/FieldID" do |ext_attr|
      tracker_field_id = ext_attr.text.to_i
    end

    doc.each_element('Project/Tasks/Task') do |task|
      begin
        logger.debug "Project/Tasks/Task found"
        struct = OpenStruct.new
        struct.level = task.get_elements('OutlineLevel')[0].try { |e| e.text.to_i }
        struct.outlinenumber = task.get_elements('OutlineNumber')[0].try { |e| e.text.strip }

        auxString = struct.outlinenumber

        index = auxString.rindex('.')
        if index
          index -= 1
          struct.outnum = auxString[0..index]
        end
        struct.tid = task.get_elements('ID')[0].try { |e| e.text.to_i }
        struct.uid = task.get_elements('UID')[0].try { |e| e.text.to_i }
        struct.title = task.get_elements('Name')[0].try { |e| e.text.strip }
        struct.start = task.get_elements('Start')[0].text.try { |e| e.split("T")[0] }
        struct.finish = task.get_elements('Finish')[0].text.try { |e| e.split("T")[0] }
        struct.priority = task.get_elements('Priority')[0].try { |e| e.text.to_i }

        s1 = task.get_elements('Start')[0].text.try(:strip)
        s2 = task.get_elements('Finish')[0].text.try(:strip)

        task.each_element("ExtendedAttribute[FieldID='#{tracker_field_id}']/Value") do |tracker_value|
          struct.tracker_name = tracker_value.text
        end

        # If the start date and the finish date are the same it is a milestone
        # struct.milestone = s1 == s2 ? 1 : 0

        struct.percentcomplete = task.get_elements('PercentComplete')[0].text.to_i
        struct.notes = task.get_elements('Notes')[0].try { |e| e.text.strip }
        struct.predecessors = []
        struct.delays = []
        task.each_element('PredecessorLink') do |predecessor|
        begin
          struct.predecessors.push(predecessor.get_elements('PredecessorUID')[0].text.to_i)
          struct.delays.push(predecessor.get_elements('LinkLag')[0].text.to_i)
        end
      end

      tasks.push(struct)

      rescue => error
        # Ignore errors; they tend to indicate malformed tasks, or at least,
        # XML file task entries that we do not understand.
        logger.debug "DEBUG: Unrecovered error getting tasks: #{error}"
      end
    end

    # Sort the array by ID. By sorting the array this way, the order
    # order will match the task order displayed to the user in the
    # project editor software which generated the XML file.

    tasks = tasks.sort_by { |task| task.uid }

    # Step through the sorted tasks. Each time we find one where the
    # *next* task has an outline level greater than the current task,
    # then the current task MUST be a summary. Record its name and
    # blank out the task from the array. Otherwise, use whatever
    # summary name was most recently found (if any) as a name prefix.

    all_categories = []
    category = ''

    tasks.each_index do |index|
      task = tasks[index]
      next_task = tasks[index + 1]

      # Instead of deleting the sumary tasks I only delete the task 0 (the project)

      #if ( next_task and next_task.level > task.level )
      #  category = task.title.strip.gsub(/:$/, '') unless task.title.nil? # Kill any trailing :'s which are common in some project files
      #  all_categories.push(category) # Keep track of all categories so we know which ones might need to be added
        #tasks[ index ] = "Prueba"
      if task.level == 0
        category = task.try { |e| e.title.strip.gsub(/:$/, '') } # Kill any trailing :'s which are common in some project files
        all_categories.push(category) # Keep track of all categories so we know which ones might need to be added
        tasks[index] = nil
      else
        task.category = category
      end
    end

    # Remove any 'nil' items we created above
    tasks.compact!
    tasks = tasks.uniq

    # Now create a secondary array, where the UID of any given task is
    # the array index at which it can be found. This is just to make
    # looking up tasks by UID really easy, rather than faffing around
    # with "tasks.find { | task | task.uid = <whatever> }".

    uid_tasks = []

    tasks.each { |task| uid_tasks[task.uid] = task }

    # OK, now it's time to parse the assignments into some meaningful
    # array. These will become our redmine issues. Assignments
    # which relate to empty elements in "uid_tasks" or which have zero
    # work are associated with tasks which are either summaries or
    # milestones. Ignore both types.

    real_tasks = []

    #doc.each_element( 'Project/Assignments/Assignment' ) do | as |
    #  task_uid = as.get_elements( 'TaskUID' )[ 0 ].text.to_i
    #  task = uid_tasks[ task_uid ] unless task_uid.nil?
    #  next if ( task.nil? )

    #  work = as.get_elements( 'Work' )[ 0 ].text
      # Parse the "Work" string: "PT<num>H<num>M<num>S", but with some
      # leniency to allow any data before or after the H/M/S stuff.
    #  hours = 0
    #  mins = 0
    #  secs = 0

    #  strs = work.scan(/.*?(\d+)H(\d+)M(\d+)S.*?/).flatten unless work.nil?
    #  hours, mins, secs = strs.map { | str | str.to_i } unless strs.nil?

      #next if ( hours == 0 and mins == 0 and secs == 0 )

      # Woohoo, real task!

    #  task.duration = ( ( ( hours * 3600 ) + ( mins * 60 ) + secs ) / 3600 ).prec_f

    #  real_tasks.push( task )
    #end
    set_assignment_to_task(doc, uid_tasks)
    logger.debug "DEBUG: Real tasks: #{real_tasks.inspect}"
    logger.debug "DEBUG: Tasks: #{tasks.inspect}"
    real_tasks = tasks if real_tasks.empty?
    real_tasks = real_tasks.uniq if real_tasks
    all_categories = all_categories.uniq.sort
    logger.debug "DEBUG: END get_tasks_from_xml"
    return real_tasks, all_categories
  end

  NOT_USER_ASSIGNED = -65535

  def set_assignment_to_task(doc, uid_tasks)

    #TODO: Are there any form to improve performance of this method ?
    resource_by_user = get_bind_resource_users(doc)
    doc.each_element('Project/Assignments/Assignment') do |as|
      task_uid = as.get_elements('TaskUID').first.text.to_i
      task = uid_tasks[task_uid] if task_uid
      next if task.nil?
      resource_id = as.get_elements('ResourceUID').first.text.to_i
      next if resource_id == NOT_USER_ASSIGNED
      task.assigned_to = resource_by_user[resource_id]
    end
  end

  def get_bind_resource_users(doc)
    resources = get_resources(doc)
    users_list = get_user_list_for_project
    users_list.sort_by { |user| user.login }
    resource_by_user = []
    resources.each do |uid, name|
      user_found = users_list.find_all { |user| user.login == name }
      next if user_found.first.nil?
      resource_by_user[uid] = user_found.first.id
    end
    return resource_by_user
  end

  def get_user_list_for_project
    user_list = @project.assignable_users
    user_list.compact!
    user_list = user_list.uniq
    return user_list
  end

  def get_resources(doc)
    resources = {}
    doc.each_element('Project/Resources/Resource') do |resource|
      resource_uid = resource.get_elements('UID').first.text.to_i
      resource_name_element = resource.get_elements('Name').first
      next if resource_name_element.nil?
      resources[resource_uid] = resource_name_element.text
    end
    return resources
  end
end
