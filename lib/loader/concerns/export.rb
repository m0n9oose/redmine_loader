module Loader::Concerns::Export
  extend ActiveSupport::Concern

  def generate_xml
    @id = 0
    request_from = Rails.application.routes.recognize_path(request.referrer)
    get_sorted_query unless request_from[:controller] =~ /loader/

    export = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      @used_issues = {}
      resources = @project.assignable_users
      xml.Project {
        xml.Title @project.name
        #xml.CreationDate @project.created_on.to_s(:ms_xml)
        #xml.StartDate @project.created_on.to_s(:ms_xml)
        xml.ExtendedAttributes {
          xml.ExtendedAttribute {
            xml.FieldID '188744001'
            xml.FieldName 'Text15'
            xml.Alias 'RID'
          }
          xml.ExtendedAttribute {
            xml.FieldID '188744002'
            xml.FieldName 'Text16'
            xml.Alias 'Tracker'
          }
        }
        xml.Calendars {
          xml.Calendar {
            @id += 1
            xml.UID @id
            xml.Name 'Standard'
            xml.IsBaseCalendar '1'
            xml.IsBaselineCalendar '0'
            xml.BaseCalendarUID '0'
            xml.Weekdays {
              (1..7).each do |day|
                xml.Weekday {
                  xml.DayType day
                  if day.in?([1, 7])
                    xml.DayWorking '0'
                  else
                    xml.DayWorking '1'
                    xml.WorkingTimes {
                      xml.WorkingTime {
                        xml.FromTime '09:00:00'
                        xml.ToTime '13:00:00'
                      }
                      xml.WorkingTime {
                        xml.FromTime '14:00:00'
                        xml.ToTime '18:00:00'
                      }
                    }
                  end
                }
              end
            }
          }
        }
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
            resources.each do |resource|
              @id += 1
              xml.Calendar {
                xml.UID resource.id
                xml.Name resource.login
                xml.IsBaseCalendar '0'
                xml.IsBaselineCalendar '0'
                xml.BaseCalendarUID '1'
              }
            end
          }

          if @export_versions
            versions = @query ? Version.where(id: @query_issues.map(&:fixed_version_id).uniq) : @project.versions
            versions.each { |version| write_version(xml, version) }
          end
          issues = (@query_issues || @project.issues.visible)
          nested_issues = determine_nesting issues, versions.try(:count)
          nested_issues.each_with_index { |issue, id| write_task(xml, issue, id) }

        }
        xml.Resources {
          xml.Resource {
            xml.UID "0"
            xml.ID "0"
            xml.Type "1"
            xml.IsNull "0"
          }
          resources.each do |resource|
            @id += 1
            xml.Resource {
              xml.UID resource.id
              xml.ID resource.id
              xml.Name resource.login
              xml.Type "1"
              xml.IsNull "0"
              xml.MaxUnits "1.00"
              xml.PeakUnits "1.00"
              xml.IsEnterprise '0'
              xml.CalendarUID resource.id
            }
          end
        }
        xml.Assignments {
          source_issues = @query ? @query_issues : @project.issues
          source_issues.select { |issue| issue.assigned_to_id? }.each do |issue|
            @id += 1
            xml.Assignment {
              time = get_scorm_time(issue.estimated_hours)
              xml.Work time
              xml.RegularWork time
              xml.RemainingWork time
              xml.DurationFormat '7'
              xml.UID @id
              xml.TaskUID issue.id
              xml.ResourceUID issue.assigned_to_id
              xml.HasFixedRateUnits '1'
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

  def determine_nesting(issues, versions_count)
    versions_count ||= 0
    nested_issues = []
    leveled_tasks = issues.sort_by(&:id).group_by(&:level)
    leveled_tasks.sort_by{ |key| key }.each do |level, grouped_issues|
      grouped_issues.each_with_index do |issue, index|
        outlinenumber = if issue.child?
          "#{nested_issues.detect{ |struct| struct.id == issue.parent_id }.try(:outlinenumber)}.#{leveled_tasks[level].index(issue).next}"
        else
          puts versions_count.nil?
          (leveled_tasks[level].index(issue).next + versions_count).to_s
        end
        nested_issues << ExportTask.new(issue, issue.level.next, outlinenumber)
      end
    end
    return nested_issues.sort_by! &:outlinenumber
  end

  def get_child_index(issue)
    issue.parent.child_ids.index(issue.id).next
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

  def get_scorm_time time
    return 'PT8H0M0S' if time.nil? || time.zero?
    atime = time.to_s.split('.')
    hours = atime.first.to_i
    minutes = atime.last.to_i == 0 ? 0 : (60 * "0.#{atime.last}".to_f).to_i
    return "PT#{hours}H#{minutes}M0S"
  end

  def write_task(xml, struct, id)
    return if @used_issues.has_key?(struct.id)
    xml.Task {
      @used_issues[struct.id] = true
      xml.UID(struct.id)
      xml.ID id.next
      xml.Name(struct.subject)
      xml.Notes(struct.description)
      xml.Active '1'
      xml.IsNull '0'
      xml.CreateDate(struct.created_on.to_s(:ms_xml))
      xml.HyperlinkAddress issue_url(struct.issue)
      xml.Priority(get_priority_value(struct.priority.name))
      start_date = struct.issue.next_working_date(struct.start_date || struct.created_on.to_date)
      xml.Start start_date.to_time.to_s(:ms_xml)
      finish_date = if struct.due_date
                      if struct.issue.next_working_date(struct.due_date).day == start_date.day
                        start_date.next
                      else
                        struct.issue.next_working_date(struct.due_date)
                      end
                    else
                      start_date.next
                    end
      xml.Finish finish_date.to_time.to_s(:ms_xml)
      xml.ManualStart start_date.to_time.to_s(:ms_xml)
      xml.ManualFinish finish_date.to_time.to_s(:ms_xml)
      xml.EarlyStart start_date.to_time.to_s(:ms_xml)
      xml.EarlyFinish finish_date.to_time.to_s(:ms_xml)
      xml.LateStart start_date.to_time.to_s(:ms_xml)
      xml.LateFinish finish_date.to_time.to_s(:ms_xml)
      time = get_scorm_time(struct.estimated_hours)
      xml.Work time
      xml.Duration time
      xml.ManualDuration time
      xml.RemainingDuration time
      xml.RemainingWork time
      xml.DurationFormat '7'
      xml.Milestone '0'
      xml.FixedCostAccrual "3"
      xml.ConstraintType "0"
      #xml.ConstraintDate start_date.to_time.to_s(:ms_xml)
      xml.IgnoreResourceCalendar '0'
      parent = struct.leaf? ? 0 : 1
      xml.Summary(parent)
      xml.Critical(parent)
      xml.Rollup(parent)
      xml.Type(parent)
      if @export_versions && struct.fixed_version_id
        xml.PredecessorLink {
          xml.PredecessorUID struct.fixed_version_id
          xml.CrossProject '0'
        }
      end
      if struct.relations_to_ids.any?
        struct.relations.select { |ir| ir.relation_type == 'precedes' }.each do |relation|
          xml.PredecessorLink {
            xml.PredecessorUID relation.issue_from_id
            if struct.project_id == relation.issue_from.project_id
              xml.CrossProject '0'
            else
              xml.CrossProject '1'
              xml.CrossProjectName relation.issue_from.project.name
            end
            xml.LinkLag (relation.delay * 4800).to_s
            xml.LagFormat '7'
          }
        end
      end
      xml.ExtendedAttribute {
        xml.FieldID '188744001'
        xml.Value struct.id
      }
      xml.ExtendedAttribute {
        xml.FieldID '188744002'
        xml.Value struct.tracker.name
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
      xml.ExtendedAttribute {
        xml.FieldID '188744001'
        xml.Value version.id
      }

      xml.WBS(@id)
      xml.OutlineNumber(@id)
      xml.OutlineLevel("1")
    }
  end
end
