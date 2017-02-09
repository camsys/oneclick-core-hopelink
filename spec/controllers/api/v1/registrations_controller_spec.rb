require 'rails_helper'

RSpec.describe Api::V1::RegistrationsController, type: :controller do
  # This line is necessary to get Devise scoped tests to work.
  before(:each) { @request.env["devise.mapping"] = Devise.mappings[:user] }

  let(:user_attrs) { attributes_for(:user) }
  let(:password_typo_user_attrs) { attributes_for(:password_typo_user)}

  it 'allows user sign_up requests' do
    post :create, params: user_attrs, as: :json # DON'T wrap attrs in a user object
    response_body = JSON.parse(response.body)

    expect(response).to be_success    # test for the 200 status-code
    expect(response_body).to be       # test for response body
    expect(response_body["id"]).to be # test for id from created user
  end

  it 'errors if password does not match password_confirmation' do
    post :create, params: password_typo_user_attrs, as: :json # DON'T wrap attrs in a user object
    response_body = JSON.parse(response.body)

    expect(response).not_to be_success    # test for the 400 status-code
  end

  it 'sets user attributes properly on sign up' do
    post :create, params: user_attrs, as: :json
    created_user = User.find_by(email: user_attrs[:email])
    attrs = user_attrs.keys
    attrs_match = attrs.all? do |att|
      (user_attrs[att] == created_user[att] || [:password, :password_confirmation, :format].include?(att))
    end

    expect(attrs_match).to be_truthy
  end

end
