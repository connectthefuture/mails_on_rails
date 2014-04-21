class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception




  private

  def current_user
    @current_user ||= User.find(session[:user_id]) if session[:user_id]
  end

  def check_is_manager
    if !check_logged_in && !current_user.is_manager?
      redirect_to :root, flash: { error: "Access denied" }
    end
  end

  def check_logged_in
    unless current_user
      redirect_to :login
      return true
    end
    false
  end

  helper_method :current_user
  helper_method :check_is_manager
  helper_method :check_logged_in


end
