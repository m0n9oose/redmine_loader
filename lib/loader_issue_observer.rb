module LoaderIssueObserver
  def self.included(base)
    base.class_eval do
      def after_create(issue)
        unless issue.subject =~ /_imported/
          Mailer.issue_add(issue).deliver if Setting.notified_events.include?('issue_added')
        end
      end

      def after_save(issue)
        issue.update_column(:subject, issue.subject.gsub('_imported', '')) if issue.subject =~ /_imported/
      end
    end
  end
end
