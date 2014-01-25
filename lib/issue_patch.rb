module IssuePatch
  def self.included(base)
    base.send(:include, InstanceMethods)
    base.class_eval do
      alias_method_chain :send_notification, :aware_of_import
    end
  end


  module InstanceMethods
    def send_notification_with_aware_of_import
      if subject =~ /_imported/
        self.update_column(:subject, subject.gsub('_imported', ''))
      else
        send_notification_without_aware_of_import
      end
    end
  end
end
