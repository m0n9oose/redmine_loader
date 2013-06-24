module LoaderMailer
  def self.included(base)
    base.send(:include, ClassMethods)
  end

  module ClassMethods
    def notify_about_import(user, project, date, issues)
      set_language_if_valid(user.language)
      redmine_headers 'Project' => project.identifier
      @issues_url = url_for(:controller => 'issues',
                            :action => 'index',
                            :set_filter => 1,
                            :author_id => user.id,
                            :project_id => project.identifier,
                            :created_on => date,
                            :sort => 'due_date:asc')
      @issues = issues
      @project = project
      @project_url = url_for(:controller => 'projects', :action => 'show', :id => project.identifier)

      mail :to => user.mail,
        :subject => t(:subject) + project.name
    end
  end
end
