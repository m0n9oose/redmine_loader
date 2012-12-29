if Rails::VERSION::MAJOR < 3
	ActionController::Routing::Routes.draw do |map|
	  map.connect 'redmine_loader/:action', :controller => 'loader'
	end
else
	match 'redmine_loader/(:action)', :controller => 'loader'
end