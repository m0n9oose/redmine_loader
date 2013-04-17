module LoaderMailer
  def self.included(base)
    base.send(:include, ClassMethods)
  end

  module ClassMethods
    def notify_about_import(user, project, issues, date)
      redmine_headers 'Project' => project.identifier
      @issues_url = url_for(:controller => 'issues', :action => 'index', :set_filter => 1, :author_id => user.id, :created_on => date, :sort => 'due_date:asc')
      @issues = issues
      @project = project

      mail :to => user.mail,
        :subject => "Your tasks were imported in project #{project.name}"
    end
  end
end
