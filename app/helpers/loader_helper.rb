########################################################################
# File:    loader_helper.rb                                            #
#          Based on work by Hipposoft 2008                             #
#                                                                      #
# Purpose: Support functions for views related to Task Import objects. #
#          See controllers/loader_controller.rb for more.              #
#                                                                      #
# History: 04-Jan-2008 (ADH): Created.                                 #
#          Feb 2009 (SJS): Hacked into plugin for redmine              #
########################################################################

module LoaderHelper
  def loader_user_select_tag(project, assigned_to, index)
    select_tag "import[tasks][#{index}][assigned_to]", options_from_collection_for_select(project.assignable_users, 'id', 'name', :selected => assigned_to ), { :include_blank => true }
  end

  def loader_tracker_select_tag(project, tracker_name, index)
    tracker = (@map_trackers[tracker_name] || Setting.plugin_redmine_loader['tracker_id'])
    select_tag "import[tasks][#{index}][tracker_id]", options_from_collection_for_select(project.trackers, :id, :name, :selected => tracker)
  end

  def loader_percent_select_tag(task_percent, index)
    select_tag "import[tasks][#{index}][percentcomplete]", options_for_select((0..10).to_a.map {|p| (p*10)}, task_percent.to_i)
  end

  def loader_priority_select_tag(task_priority, index)
    priority_name = case task_priority.to_i
               when 0..200 then 'Minimal'
               when 201..400 then 'Low'
               when 401..600 then 'Normal'
               when 601..800 then 'High'
               when 801..1000 then 'Immediate'
               end
    select_tag "import[tasks][#{index}][priority]", options_from_collection_for_select(IssuePriority.active, :id, :name, :selected => priority_name)
  end

  def duplicates_count(document, titles)
    @dupes = 0
    document.tasks.each do |task|
      if titles[task.subject]
        @dupes += 1
        titles[task.subject] = @dupes
      else
        titles[task.subject] = true
      end
    end
    return @dupes
  end
end
