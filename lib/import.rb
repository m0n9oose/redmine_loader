class Import
  @tasks      = []
  project_id = nil
  @new_categories = []
  @hashed_name = nil
  update_existing = true

  attr_accessor :tasks, :project_id, :new_categories, :hashed_name, :update_existing

  def self.clean_up(import_name)
    FileUtils.rm Dir["./#{import_name}_*"] # remove temp files
  end

end
