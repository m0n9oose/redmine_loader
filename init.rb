require 'redmine'

require_dependency 'loader'

Redmine::Plugin.register :redmine_loader do

  name 'Basic project file loader for Redmine'

  author 'Simon Stearn largely hacking Andrew Hodgkinsons trackrecord code (sorry Andrew)'

  description 'Basic project file loader'

  version '0.0.12'

  requires_redmine :version_or_higher => '0.9.2'

  # Commented out because it refused to work in development mode
  default_tracker_name = 'Features' #Tracker.find_by_id( 1 ).name
  default_tracker_alias = 'Tracker'

  settings :default => {
	:tracker => default_tracker_name,
	:tracker_alias => default_tracker_alias
  }, :partial => 'settings/loader_settings'


  project_module :project_xml_importer do
    permission :import_issues_from_xml, :loader => [:new, :create]
  end

  menu :project_menu, :loader, { :controller => 'loader', :action => 'new' },
    :caption => :menu_caption, :after => :new_issue, :param => :project_id

  # MS Project used YYYY-MM-DDTHH:MM:SS format. There no support of time zones, so time will be in UTC
  Time::DATE_FORMATS.merge!(
    :ms_xml => lambda{ |time| time.utc.strftime("%Y-%m-%dT%H:%M:%S") }
  )

  # MS Project used YYYY-MM-DDTHH:MM:SS format. There no support of time zones, so time will be in UTC
  Time::DATE_FORMATS.merge!(
    :ms_xml => lambda{ |time| time.utc.strftime("%Y-%m-%dT%H:%M:%S") }
  )
end

