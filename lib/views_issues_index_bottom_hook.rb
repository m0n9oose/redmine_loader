class Hooks < Redmine::Hook::ViewListener
  render_on :view_issues_index_bottom,
            :partial => "loader/other_formats_builder"
end
