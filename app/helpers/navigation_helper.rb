module NavigationHelper
  NavItem = Struct.new(:label, :path, :active, keyword_init: true)

  # Sidebar navigation. Items with a nil path render as disabled placeholders
  # until their section is built.
  def nav_items
    [
      NavItem.new(label: "Dashboard", path: root_path, active: current_page?(root_path)),
      NavItem.new(label: "Projects", path: nil, active: false),
      NavItem.new(label: "Pipelines", path: nil, active: false),
      NavItem.new(label: "Workers", path: nil, active: false),
      NavItem.new(label: "Step Library", path: nil, active: false)
    ]
  end
end
