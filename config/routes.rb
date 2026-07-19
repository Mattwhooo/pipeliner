Rails.application.routes.draw do
  devise_for :users
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "home#index"
  get "fleet_health", to: "home#fleet_health", as: :dashboard_fleet_health

  resources :projects, only: [ :index, :show, :new, :create ] do
    resources :pipelines, only: [ :new, :create ]
    resource :pipeline_template, only: [ :show, :update ] do
      resources :steps, only: [ :create, :destroy ], controller: "pipeline_template_steps" do
        post :move, on: :member
      end
    end
  end
  resources :pipelines, only: [ :index, :show ] do
    member do
      post :merge
      post :update_from_base
    end
  end
  resources :workers, only: [ :index ]
  resources :step_templates, path: "step-library"
  resources :phases, only: [ :show ] do
    resources :steps, only: [ :new, :create ]
    resource :approval, only: [ :create ]
    member do
      post :send_back
      post :answers
      post :submit_feedback
      post :pause
      post :rerun_step
      post :restart
    end
  end
  resources :steps, only: [] do
    post :queue_run, on: :member
  end

  namespace :api do
    namespace :v1 do
      post "workers/register", to: "registrations#create"
      resources :claims, only: [ :create ]
      resources :step_runs, only: [] do
        member do
          post :heartbeat
          post :progress
          post :complete
        end
      end
    end
  end
end
