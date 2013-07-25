class String
  # try to convert redmine field name to msp
  def msp_name
    msp_name = case self
               when 'description'       then 'notes'
               when 'start_date'        then 'start'
               when 'due_date'          then 'finish'
               when 'estimated_hours'   then 'duration'
               when 'subject'           then 'title'
               when 'done_ratio'        then 'percentcomplete'
               else self.to_s
               end
    return msp_name
  end
end
