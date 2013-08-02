module SettingsHelperPatch
  def self.included(base)
    base.class_eval do
      def loader_setting_checkbox *setting_path
        content_tag :p do
          label_tag("settings_#{setting_path.join('_')}", t("field_#{setting_path.last}")) +
          hidden_field_tag("settings[#{setting_path.join('][')}]", 0, id: nil) +
          check_box_tag("settings[#{setting_path.join('][')}]", 1, (setting_path.inject(@settings){ |obj, item| obj[item] || break } == '1' ? true : false))
        end
      end
    end
  end
end
