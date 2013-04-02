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

  # Generate a project selector for the project to which imported tasks will
  # be assigned. HTML is output which is suitable for inclusion in a table
  # cell or other similar container. Pass the form object being used for the
  # task import view.

  def project_selector(form)
    project_list = Project.find(:all, :conditions => Project.visible_by(User.current))

    unless project_list.empty?
      output  = "        &nbsp;Project to which all tasks will be assigned:\n"
      output  << "<select id=\"import_project_id\" name=\"import[project_id]\"><optgroup label=\"Your Projects\"> "

      project_list.each do |project|
        output = output + "<option value=\"" + project.id.to_s + "\">" + project.to_s + "</option>"
      end
      output << "</optgroup>"
      output << "</select>"

    else
      output  = "        There are no projects defined. You can create new\n"
      output << "        projects #{ link_to( 'here', '/project/new' ) }."
    end

    return output
  end

  # Generate a category selector to which imported tasks will
  # be assigned. HTML is output which is suitable for inclusion in a table
  # cell or other similar container. Pass the form object being used for the
  # task import view.

  def category_selector(field_id, project, all_new_categories, requested_category)

    # First populate the selection box with all the existing categories from this project
    category_list = IssueCategory.find(:all, :conditions => { :project_id => project })

    output = "<select id=\"" + field_id + "\" name=\"" + field_id + "\"> "
    # Empty entry
    output << "<option value=\"\"></option>"
    output << "<optgroup label=\"Existing Categories\"> "

    category_list.each do |category|
      if category.to_s == requested_category
        output << "<option value=\"" + category.to_s + "\" selected=\"selected\">" + category.to_s + "</option>"
      else
        output << "<option value=\"" + category.to_s + "\">" + category.to_s + "</option>"
      end
    end

    output << "</optgroup>"

    # Now add any new categories that we found in the project file
    #output << "<optgroup label=\"New Categories\"> "

    #all_new_categories.each do | category_name |
    #  if ( not category_list.include?(category_name) )
    #    if ( category_name == requested_category )
    #      output << "<option value=\"" + category_name + "\" selected=\"selected\">" + category_name + "</option>"
    #    else
    #      output << "<option value=\"" + category_name + "\">" + category_name + "</option>"
    #    end
    #  end
    #end

    #output << "</optgroup>"
    output << "</select>"
    return output
  end

  # Generate a user selector to which imported tasks will
  # be assigned. HTML is output which is suitable for inclusion in a table
  # cell or other similar container. Pass the form object being used for the
  # task import view.

  def user_selector(field_id, project, assigned_to)
    # First populate the selection box with all the existing categories from this project
    user_list = project.assignable_users
    user_list.compact!
    user_list = user_list.uniq
    output = "<select id=\"" + field_id + "\" name=\"" + field_id + "\">"

    # Empty entry
    output << "<option value=\"\"></option>"
    # Add all the users
    user_list = user_list.sort {|a, b| a.firstname + a.lastname <=> b.firstname + b.lastname}
    user_list.each do |user_entry|
      output << "<option value=\"" + user_entry.id.to_s + "\""
      output << " selected='selected' " if assigned_to && assigned_to == user_entry.id
      output << " >" + user_entry.firstname + " " + user_entry.lastname + "</option>"
    end
    output << "</select>"
    return output
  end

  def tracker_selector(field_id, project)
    tracker_list = project.trackers
    output = "<select id=\"" + field_id + "\" name=\"" + field_id + "\">"
    tracker_list.each do |tracker|
      output << "<option value=\"" + tracker.name.to_s + "\""
      output << " selected='selected' " if Setting.plugin_redmine_loader['tracker'].downcase == tracker.name.to_s.downcase
      output << " >" + tracker.name.capitalize + "</option>"
    end
    output << "</select>"
    return output
  end

  def percent_selector(field_id, task_percent)
    output = "<select id=\"" + field_id + "\" name=\"" + field_id + "\">"
    ((0..10).to_a.map {|p| p*10 }).each do |percent|
      output << "<option value=\"" + percent.to_s + "\""
      output << " selected='selected' " if task_percent == percent
      output << " >" + percent.to_s + "</option>"
    end
    output << "</select>"
    return output
  end

  def duplicates_count(document, titles)
    @dupes = 0
    document.tasks.each do |task|
      if titles[task.title]
        @dupes += 1
        titles[task.title] = @dupes
      else
        titles[task.title] = true
      end
    end
    return @dupes
  end
end
