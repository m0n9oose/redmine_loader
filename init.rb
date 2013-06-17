require 'redmine'

require_dependency 'loader'
require_dependency 'views_issues_index_bottom_hook'

ActionDispatch::Callbacks.to_prepare do
  Mailer.__send__(:include, LoaderMailer)
  IssueObserver.__send__(:include, LoaderIssueObserver)
  Redmine::Views::OtherFormatsBuilder.__send__(:include, LoaderOtherFormatsBuilder)
end

Redmine::Plugin.register :redmine_loader do

  name 'Basic project file loader for Redmine'

  author 'Simon Stearn largely hacking Andrew Hodgkinsons trackrecord code (sorry Andrew)'

  description 'Basic project file loader'

  version '0.1'

  requires_redmine :version_or_higher => '2.3.0'

  # Commented out because it refused to work in development mode
  default_tracker_alias = 'Tracker'

  settings :default => {
	:tracker_alias => default_tracker_alias,
	:instant_import_tasks => 10
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

