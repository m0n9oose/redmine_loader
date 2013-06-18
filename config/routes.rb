resources :projects do
  resource :loader, :only => [:new, :create], :controller => :loader do
    get :export
    post :analyze
  end
end
