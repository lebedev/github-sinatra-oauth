require 'sinatra'
require 'sinatra/activerecord'
require 'rest-client'
require 'json'

require './models.rb'

CLIENT_ID = ENV['GH_BASIC_CLIENT_ID']
CLIENT_SECRET = ENV['GH_BASIC_SECRET_ID']

use Rack::Session::Pool, :cookie_only => false

def authenticated?
  session[:access_token]
end

def with_error_handling(should_logout_on_404 = false)
  yield
rescue RestClient::Exception => e
  if should_logout_on_404 and e.http_code.to_i === 404
    # request didn't succeed because the token was revoked so we
    # invalidate the token stored in the session and redirect to
    # error page so that the user can start the OAuth flow again

    session[:access_token] = nil
  end
  redirect '/error'
end

def get_user(access_token)
  # get a user using the valid token
  with_error_handling do
    RestClient.get('https://api.github.com/user',
                   {:params => {:access_token => access_token},
                    :accept => :json})
  end
end

get '/login' do
  if authenticated?
    redirect '/dashboard'
  else
    erb :login, :locals => {:client_id => CLIENT_ID}
  end
end

get '/dashboard' do
  access_token = session[:access_token]

  with_error_handling(true) do
    token_check_url = "https://api.github.com/applications/#{CLIENT_ID}/tokens/#{access_token}"
    RestClient::Request.execute({method: :get, url: token_check_url, user: CLIENT_ID, password: CLIENT_SECRET})
  end

  auth_result = get_user(access_token)

  login = JSON.parse(auth_result)['login']

  user = User.find_by(login: login)

  erb :dashboard, :locals => user.as_json
end

get '/callback' do
  # get temporary GitHub code...
  session_code = request.env['rack.request.query_hash']['code']

  # ... and POST it back to GitHub
  result = with_error_handling do
    RestClient.post('https://github.com/login/oauth/access_token',
                    {:client_id => CLIENT_ID,
                     :client_secret => CLIENT_SECRET,
                     :code => session_code},
                     :accept => :json)
  end

  # extract the token
  access_token = JSON.parse(result)['access_token']

  # save the token to a session
  session[:access_token] = access_token

  auth_result = get_user(access_token)

  # check the list of current scopes
  if auth_result.headers.include? :x_oauth_scopes
    scopes = auth_result.headers[:x_oauth_scopes].split(', ')
  else
    scopes = []
  end

  user = JSON.parse(auth_result)

  if scopes.include? 'user:email'
    user['private_emails'] = with_error_handling do
      JSON.parse(RestClient.get('https://api.github.com/user/emails',
                                {:params => {:access_token => access_token},
                                 :accept => :json}))
    end
  end

  login = user['login']
  email = user['email']
  private_emails = user['private_emails']

  # upsert the user to DB
  user_in_db = User.find_or_create_by(login: login)
  user_in_db.email = (!email.nil? && !email.empty?) ? email : nil
  user_in_db.private_emails = (!private_emails.nil? && !private_emails.empty?) ? private_emails.map{ |private_email|
    private_email['email']
  }.join(', ') : nil

  user_in_db.save

  redirect '/dashboard'
end

post '/logout' do
  session[:access_token] = nil
  redirect '/login'
end

get '/error' do
  erb :error
end

get '*' do
  if authenticated?
    redirect '/dashboard'
  else
    redirect '/login'
  end
end
