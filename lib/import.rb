class Import
  require 'yaml'

  @tasks = []
  @hashed_name = nil
  NOT_USER_ASSIGNED = -65535

  attr_accessor :tasks, :project_id, :hashed_name, :update_existing

  def self.clean_up(import_name)
    FileUtils.rm Dir["./#{import_name}_*"] # remove temp files
  end

  def self.import_tasks(to_import, project_id, user, hashed_name=nil, update_existing=false, sync_versions=false)
    puts "DEBUG: #{__method__.to_s} started"

    # We're going to keep track of new issue ID's to make dependencies work later
    uid_to_issue_id = {}
    # keep track of new Version ID's
    uid_to_version_id = {}
    # keep track of the outlineNumbers to set the parent_id
    outlinenumber_to_issue_id = {}

    Issue.transaction do
      to_import.each do |source_issue|
        unless source_issue.milestone.to_i == 1
          issue = update_existing ? Issue.where("id = ? AND project_id = ?", source_issue.tid, project_id).first_or_initialize : Issue.new
          issue.tracker_id = source_issue.tracker_id
          issue.subject = source_issue.subject.slice(0, 246) + '_imported' # Max length of this field is 255
          issue.project_id = project_id
          issue.author_id = user.id
          issue.is_private = source_issue.try(:is_private) ? 1 : 0
          %w(start_date due_date description done_ratio estimated_hours status_id).each do |field|
            eval("issue.#{field} = source_issue.try(:#{field})")
          end
          if issue.due_date.nil? && issue.start_date
            issue.due_date = (Date.parse(source_issue.start, false) + ((source_issue.duration.to_f/40.0)*7.0).to_i).to_s
          end

          issue.assigned_to_id = source_issue.assigned_to

          if issue.save!
            puts "DEBUG: Issue #{issue.subject} imported"

            if source_issue.spent_hours.to_f > issue.total_spent_hours
              TimeEntry.create do |te|
                te.user_id = source_issue.assigned_to
                te.project_id = project_id
                te.hours = source_issue.spent_hours.to_f - issue.total_spent_hours
                te.spent_on = Date.today
                te.issue_id = issue.id
              end
            end
          end

          # Now that we know this issue's Redmine issue ID, save it off for later
          uid_to_issue_id[source_issue.uid] = issue.id
          #Save the Issue's ID with the outlineNumber as an index, to set the parent_id later
          outlinenumber_to_issue_id[source_issue.outlinenumber] = issue.id
        else
          if sync_versions
            # If the issue is a milestone we save it as a Redmine Version
            version_record = Version.where("name = ? AND project_id = ?", source_issue.title, project_id).first_or_initialize
            version_record.name = source_issue.title.slice(0, 59) # maximum is 60 characters
            version_record.description = source_issue.try(:notes)
            version_record.effective_date = source_issue.start
            version_record.project_id = project_id
            version_record.save
            # Store the version_record.id to assign the issues to the version later
            uid_to_version_id[source_issue.uid] = version_record.id
          end
        end
      end
    end

    # store mapped ids to file, so we can use them later

    if hashed_name
      issues_filename = hashed_name + '_uid_to_issue_id'
      outlinenumber_filename = hashed_name + '_outlinenumber_to_issue_id'
      File.open(issues_filename, 'a') { |file| file << uid_to_issue_id.to_yaml }
      File.open(outlinenumber_filename, 'a') { |file| file << outlinenumber_to_issue_id.to_yaml }
      if sync_versions
        versions_filename = hashed_name + '_uid_to_version_id'
        File.open(versions_filename, 'a') { |file| file << uid_to_version_id.to_yaml }
      end
    else
      return uid_to_issue_id, outlinenumber_to_issue_id, uid_to_version_id
    end
  end

  def self.map_subtasks_and_parents(tasks, project_id, hashed_name=nil, uid_to_issue_id=nil, outlinenumber_to_issue_id=nil)
    puts "DEBUG: #{__method__.to_s} started"
    puts "tasks: #{tasks.try(:size)}, hashed_name: #{hashed_name}, project: #{project_id}"

    if hashed_name
      uid_to_issue_id = File.open((hashed_name + '_uid_to_issue_id'), 'r') do |file|
        uids = YAML::load_documents(file)
        uids.reduce(:merge)
      end

      outlinenumber_to_issue_id = File.open((hashed_name + '_outlinenumber_to_issue_id'), 'r') do |file|
        outlinenumbers = YAML::load_documents(file)
        outlinenumbers.reduce(:merge)
      end
    end

    Issue.transaction do
      tasks.each do |source_issue|
        parent_outlinenumber = source_issue[:outlinenumber].split('.')[0...-1].join('.')
        if parent_outlinenumber.present?
          if destination_issue = Issue.find_by_id_and_project_id(uid_to_issue_id[source_issue[:uid]], project_id)
            destination_issue.update_attributes(parent_issue_id: outlinenumber_to_issue_id[parent_outlinenumber])
          end
        end
      end
    end
  end

  def self.map_versions_and_relations(milestones, tasks, project_id, hashed_name=nil, sync_versions=false, uid_to_issue_id=nil, uid_to_version_id=nil)
    puts "DEBUG: #{__method__.to_s} started"
    if hashed_name
      uid_to_issue_id = File.open((hashed_name + '_uid_to_issue_id'), 'r') do |file|
        uids = YAML::load_documents(file)
        uids.reduce(:merge)
      end

      if sync_versions
        uid_to_version_id = File.open((hashed_name + '_uid_to_version_id'), 'r') do |file|
          uid_to_version_id = YAML::load_documents(file)
          uid_to_version_id.reduce(:merge)
        end
      end
    end

    if sync_versions
      milestones.each do |milestone|
        issue_ids = tasks.select { |i| i.predecessors.include? milestone.uid.to_s }.map { |task| uid_to_issue_id[task.uid] }
        Issue.where("id IN (?) AND project_id = ?", issue_ids, project_id).each do |issue|
          issue.update_attributes(:fixed_version_id => uid_to_version_id[milestone.uid])
        end
      end
    end

    # Delete all the relations off the issues that we are going to import. If they continue existing we are going to create them. If not they must be deleted.
    tasks.each do |source_issue|
      IssueRelation.delete_all(["issue_to_id = ?", source_issue.uid])
    end

    # Handle all the dependencies being careful if the parent doesn't exist
    IssueRelation.transaction do
      tasks.each do |source_issue|
        #delaynumber = 0
        source_issue.predecessors.each do |parent_uid|
          # Parent is being imported also. Go ahead and add the association
          if uid_to_issue_id.has_key?(parent_uid)
            # If the issue is not a milestone we have to create the issue relation
            IssueRelation.new do |relation|
              relation.issue_from_id = uid_to_issue_id[parent_uid]
              relation.issue_to_id = uid_to_issue_id[source_issue.uid]
              relation.relation_type = 'precedes'
              # Set the delay of the relation if it exists.
              #if source_issue.try { |e| e.delays[delaynumber].to_i > 0 }
              #  i.delay = (source_issue.delays[delaynumber].to_i)/4800
              #  delaynumber = delaynumber + 1
              #end
              relation.save
            end
          end
        end
      end
    end
  end
end
