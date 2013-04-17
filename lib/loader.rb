########################################################################
# File:    loader.rb                                                   #
#          Based on work by Hipposoft 2008                             #
#                                                                      #
# Purpose: Encapsulate data required for a loader session.             #
#                                                                      #
# History: 16-May-2008 (ADH): Created.                                 #
#          Feb 2009 (SJS): Hacked into plugin for redmine              #
########################################################################

class TaskImport
  @tasks      = []
  project_id = nil
  @new_categories = []

  attr_accessor :tasks, :project_id, :new_categories
end

class Loader

 def self.import_tasks(to_import, project, user)

    # We're going to keep track of new issue ID's to make dependencies work later
    uidToIssueIdMap = {}
    # keep track of new Version ID's
    uidToVersionIdMap = {}
    # keep track of the outlineNumbers to set the parent_id
    outlineNumberToIssueIDMap = {}

    Issue.transaction do
      to_import.each do |source_issue|

        # We comment those lines becouse they are not necesary now.
        # Add the category entry if necessary
        #category_entry = IssueCategory.find :first, :conditions => { :project_id => project.id, :name => source_issue.category }
        puts "DEBUG: Issue to be imported: #{source_issue.inspect}"
        if source_issue.category.present?
          puts "DEBUG: Search category id by name: #{source_issue.category}"
          category_entry = IssueCategory.find(:first, :conditions => { :project_id => project.id, :name => source_issue.category })
          puts "DEBUG: Category found: #{category_entry.inspect}"
        end

        if source_issue.tracker_name.present?
          puts "DEBUG: Search tracker id by name: #{source_issue.tracker_name}"
          final_tracker = Tracker.find(:first, :conditions => ["name = ?", source_issue.tracker_name])
          puts "DEBUG: Tracker found: #{final_tracker.inspect}"
        else
          final_tracker = default_tracker
        end

        if source_issue.milestone.to_i == 0
          destination_issue = Issue.find(:first, :conditions => ["project_id = ? AND id = ?", project.id, source_issue.uid]) || Issue.new
          destination_issue.tracker_id = final_tracker.id
          destination_issue.category_id = category_entry.try(:id)
          destination_issue.subject = source_issue.title.slice(0, 246) + '_imported' # Max length of this field is 255
          destination_issue.estimated_hours = source_issue.duration
          destination_issue.project_id = project.id
          destination_issue.author_id = user.id
          destination_issue.lock_version = 0
          destination_issue.done_ratio = source_issue.try(:percentcomplete)
          destination_issue.start_date = source_issue.try(:start)
          destination_issue.due_date = source_issue.try(:finish)
          if destination_issue.due_date.nil? && destination_issue.start_date
            destination_issue.due_date = (Date.parse(source_issue.start, false) + ((source_issue.duration.to_f/40.0)*7.0).to_i).to_s
          end
          destination_issue.description = source_issue.try(:notes)

          puts "DEBUG: Assigned_to field: #{source_issue.assigned_to}"

          destination_issue.assigned_to_id = source_issue.assigned_to if source_issue.assigned_to
          destination_issue.try(:save!)

          puts "DEBUG: Issue #{destination_issue.subject} imported"
          # Now that we know this issue's Redmine issue ID, save it off for later
          uidToIssueIdMap[source_issue.uid] = destination_issue.id
          #Save the Issue's ID with the outlineNumber as an index, to set the parent_id later
          outlineNumberToIssueIDMap[source_issue.outlinenumber] = destination_issue.id
        else
          #If the issue is a milestone we save it as a Redmine Version
          version_record = Version.find(:first, :conditions => ["project_id = ? AND id = ?", project.id, source_issue.uid]) || Version.new
          version_record.name = source_issue.title.slice(0, 59)#maximum is 60 characters
          version_record.description = source_issue.try(:notes)
          version_record.effective_date = source_issue.start
          version_record.project_id = project.id
          version_record.try(:save!)
          # Store the version_record.id  to assign the issues to the version later
          uidToVersionIdMap[ source_issue.uid ] = version_record.id
        end
      end

      #flash[:notice] = l(:imported_successfully) + to_import.length.to_s
    end

    # Set the parent_id. We use the outnum of the issue (the outlineNumber without the last .#).
    # This outnum is the same as the parent's outlineNumber, so we can use it as the index of the
    # outlineNumberToIssueIDMap to get the parent's ID
    Issue.transaction do
      to_import.each do |source_issue|
        destination_issue = Issue.find(:first, :conditions => ["project_id = ? AND id = ?", project.id, uidToIssueIdMap[source_issue.uid]])
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
              destination_issue = Issue.find(:first, :conditions => ["project_id = ? AND id = ?", project.id, uidToIssueIdMap[parent_uid]])
              destination_issue.fixed_version_id = uidToVersionIdMap[source_issue.uid]
              destination_issue.save!
            end
          end
        end
      end
    end
  end
end
