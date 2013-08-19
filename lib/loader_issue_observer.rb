module LoaderIssueObserver
  def self.included(base)
    base.class_eval do
      base.send(:include, InstanceMethods)

      alias_method_chain :after_create, :notify_about_import

      def after_save(issue)
        issue.update_column(:subject, issue.subject.gsub('_imported', '')) if issue.subject =~ /_imported/
      end
    end
  end

  module InstanceMethods
    def after_create_with_notify_about_import(issue)
      after_create_without_notify_about_import(issue) unless issue.subject =~ /_imported/
    end
  end
end
