class ExportTask < Struct.new(:issue, :outlinelevel, :outlinenumber, :uid)

  def method_missing method
    self.issue.send method if self.issue.respond_to? method
  end
end
