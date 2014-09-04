require 'redmine'

require_dependency 'string'
require_dependency 'element'
require_dependency 'views_issues_index_bottom_hook'

ActionDispatch::Callbacks.to_prepare do
  SettingsHelper.__send__(:include, SettingsHelperPatch)
  Mailer.__send__(:include, LoaderMailer)
  Issue.__send__(:include, IssuePatch)
  Redmine::Views::OtherFormatsBuilder.__send__(:include, LoaderOtherFormatsBuilder)
end

Redmine::Plugin.register :redmine_loader do

  author 'Simon Stearn, Andrew Hodgkinsons'

  desc = 'MS Project/Redmine sync plugin'
  name desc
  description desc

  version '0.3b'

  requires_redmine version_or_higher: '2.3.0'

  settings default: {
    tracker_alias: 'Tracker',
    redmine_id_alias: 'RID',
    redmine_status_alias: 'RSTATUS',
    export: {
      sync_versions: false,
      ignore_fields: {
        description: false,
        priority: false,
        done_ratio: false,
        estimated_hours: false,
        spent_hours: false
      }
    },
    import: {
      is_private_by_default: false,
      instant_import_tasks: 10,
      sync_versions: false,
      ignore_fields: {
        description: false,
        priority: false,
        done_ratio: false,
        estimated_hours: false,
        spent_hours: false
      }
    },
  }, partial: 'settings/loader_settings'


  project_module :project_xml_importer do
    permission :import_issues_from_xml, loader: [:new, :create]
    permission :export_issues_to_xml, loader: :export
  end

  menu :project_menu, :loader, { controller: :loader, action: :new },
    caption: :menu_caption, after: :new_issue, param: :project_id

  Time::DATE_FORMATS.merge!(
    ms_xml: lambda{ |time| time.strftime("%Y-%m-%dT%H:%M:%S") }
  )
end
