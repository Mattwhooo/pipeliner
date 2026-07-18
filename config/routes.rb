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

  resources :projects, only: [ :index, :show, :new, :create ] do
    resources :pipelines, only: [ :new, :create ]
  end
  resources :pipelines, only: [ :index, :show ]
  resources :workers, only: [ :index ]
  resources :step_templates, path: "step-library"
  resources :phases, only: [] do
    resources :steps, only: [ :new, :create ]
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
