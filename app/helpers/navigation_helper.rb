module NavigationHelper
  NavItem = Struct.new(:label, :path, :active, keyword_init: true)

  # Sidebar navigation. Items with a nil path render as disabled placeholders
  # until their section is built.
  def nav_items
    [
      NavItem.new(label: "Dashboard", path: root_path, active: current_page?(root_path)),
      NavItem.new(label: "Projects", path: projects_path,
        active: controller_name == "projects"),
      NavItem.new(label: "Pipelines", path: pipelines_path,
        active: controller_name == "pipelines"),
      NavItem.new(label: "Workers", path: workers_path,
        active: controller_name == "workers"),
      NavItem.new(label: "Step Library", path: step_templates_path,
        active: controller_name == "step_templates")
    ]
  end
end
