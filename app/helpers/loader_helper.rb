module LoaderHelper
  def loader_user_select_tag(project, assigned_to, index)
    select_tag "import[tasks][#{index}][assigned_to]", options_from_collection_for_select(project.assignable_users, :id, :name, assigned_to ), { include_blank: true }
  end

  def loader_tracker_select_tag(project, tracker_name, index)
    tracker_id = if map_trackers.has_key?(tracker_name)
                   map_trackers[tracker_name]
                 else
                   @settings[:import][:tracker_id]
                 end
    select_tag "import[tasks][#{index}][tracker_id]", options_from_collection_for_select(project.trackers, :id, :name, tracker_id)
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
    select_tag "import[tasks][#{index}][priority]", options_from_collection_for_select(IssuePriority.active, :id, :name, priority_name)
  end

  def ignore_field?(field, way)
    field.to_s.in?(@ignore_fields.send(:fetch, way.to_sym))
  end

  def duplicate_index task_subject
    @duplicates.index(task_subject).next if task_subject.in?(@duplicates)
  end

  def map_trackers
    @map_trackers ||= Hash[@project.trackers.map { |tracker| [tracker.name, tracker.id] }]
  end
end
