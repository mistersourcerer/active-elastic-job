require 'spec_helper'
require 'rack/mock'
require 'rails'

describe ActiveElasticJob::Rack::SqsMessageConsumer do
  let(:env) { Rack::MockRequest.env_for("http://example.com:8080/") }
  let(:app) { double("app") }
  let(:original_response) { double("original_response") }
  let(:secret_key_base) { 's3krit' }
  let(:rails_app) { double("rails_app") }

  subject(:sqs_message_consumer) {
    ActiveElasticJob::Rack::SqsMessageConsumer.new(app)
  }

  before do
    allow(sqs_message_consumer).to receive(:secret_key_base) { secret_key_base }
    allow(sqs_message_consumer).to receive(:periodic_tasks_route) { '/periodic_tasks' }
    allow(sqs_message_consumer).to receive(:enabled?) { true }
  end

  it "passes an ordinary request through" do
    expect(app).to receive(:call).with(env).and_return(original_response)
    expect(sqs_message_consumer.call(env)).to eq(original_response)
  end

  context "when user agent matches" do
    let(:job) { Helpers::TestJob.new('test') }
    let(:origin_attribute) { 'AEJ' }

    before do
      verifier = ActiveElasticJob::MessageVerifier.new(secret_key_base)
      message_body = JSON.dump(job.serialize)
      digest = verifier.generate_digest(message_body)
      env['HTTP_X_AWS_SQSD_ATTR_MESSAGE_DIGEST'] = digest
      env['HTTP_X_AWS_SQSD_ATTR_ORIGIN'] = origin_attribute
      env['HTTP_USER_AGENT'] = 'aws-sqsd/1.1'
      env['rack.input'] = StringIO.new(message_body)
    end

    context "when request was not local" do
      before do
        env['REMOTE_ADDR'] = '64.15.113.183'
      end

      it "responds with a 403 status code" do
        response = sqs_message_consumer.call(env)
        expect(response[0]).to eq('403')
      end
    end

    context "when request was local" do
      before do
        env['REMOTE_ADDR'] = '127.0.0.1'
      end
      context "when origin is not set" do
        let(:origin_attribute) { nil }

        context "when disgest is ommited" do
          before do
            env['HTTP_X_AWS_SQSD_ATTR_MESSAGE_DIGEST'] = nil
          end
          it "passes request through" do
            expect(app).to receive(:call).with(env).
              and_return(original_response)
            expect(sqs_message_consumer.call(env)).to eq(original_response)
          end
        end

        context "when digest is present" do
          it "intercepts request" do
            expect(app).not_to receive(:call).with(env)
            sqs_message_consumer.call(env)
          end
        end
      end

      context "when origin is not Active Elastic Job" do
        let(:origin_attribute) { "some thing else" }
        before do
          env['HTTP_X_AWS_SQSD_ATTR_MESSAGE_DIGEST'] = nil
        end

        it "passes request through" do
          expect(app).to receive(:call).with(env).and_return(original_response)
          expect(sqs_message_consumer.call(env)).to eq(original_response)
        end
      end

      context "when origin is Active Elastic Job" do
        let(:origin_attribute) { "AEJ" }

        it "intercepts request" do
          expect(app).not_to receive(:call).with(env)
          sqs_message_consumer.call(env)
        end

        it "performs the job" do
          expect(sqs_message_consumer.call(env)[0]).to eq('200')
        end

        context "when digest is ommited" do
          before do
            env['HTTP_X_AWS_SQSD_ATTR_MESSAGE_DIGEST'] = nil
          end

          it "responds with a 403 status code" do
            response = sqs_message_consumer.call(env)
            expect(response[0]).to eq('403')
          end
        end

        context "when digest is forged" do
          before do
            env['HTTP_X_AWS_SQSD_ATTR_MESSAGE_DIGEST'] = 'forged'
          end

          it "responds with a 403 status code" do
            response = sqs_message_consumer.call(env)
            expect(response[0]).to eq('403')
          end
        end

        context "running under Puma" do
          let(:current_server) { double("Puma Server") }

          before do
            unless defined?(Puma::Server)
              Object.const_set("Puma", Module.new)
              Puma.const_set("Server", Module.new)
            end

            allow(Puma::Server).to receive(:current).and_return current_server
          end

          context "when worker is shutting down" do
            before do
              allow(current_server).to receive(:shutting_down?).and_return(true)
            end

            it "does not accepts new messages" do
              expect(sqs_message_consumer.call(env)[0]).to eq('503')
            end
          end

          context "when worker is running normally" do
            before do
              allow(current_server).to receive(:shutting_down?).and_return(false)
            end

            it "does not accepts new messages" do
              expect(sqs_message_consumer.call(env)[0]).to eq('200')
            end
          end
        end
      end
    end
  end
end
