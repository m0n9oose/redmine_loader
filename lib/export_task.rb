class ExportTask < Struct.new(:issue, :outlinelevel, :outlinenumber, :uid)

  def method_missing method
    issue.send method if issue.respond_to? method
  end
end
