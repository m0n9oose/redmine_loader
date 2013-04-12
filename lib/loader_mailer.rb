module LoaderMailer
  def self.included(base)
    base.send(:include, ClassMethods)
  end

  module ClassMethods
    def notify_about_import(user, project, imported)
      redmine_headers 'Project' => project.identifier
      @issues = imported
      @project = project

      mail :to => user.mail,
        :subject => "Your tasks were imported in project #{project.name}"
    end
  end
end
