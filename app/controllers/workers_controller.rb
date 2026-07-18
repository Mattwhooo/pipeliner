class WorkersController < ApplicationController
  def index
    @workers = Worker.order(:public_id)
  end
end
