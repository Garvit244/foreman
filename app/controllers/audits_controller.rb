require 'lib/audit_extensions'
class AuditsController < ApplicationController
  include Foreman::Controller::AutoCompleteSearch
  def index
    Audit.unscoped { @audits = Audit.search_for(params[:search], :order => params[:order]).paginate :page => params[:page] }
  rescue => e
    error e.to_s
    @audits = Audit.search_for('', :order => params[:order]).paginate :page => params[:page]
  end

  def show
    @audit = Audit.find(params[:id])
  end
end
