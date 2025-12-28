require 'rake'

desc "Install dependencies"
task :install do
  sh "bundle install"
end

desc "Setup VPN node (install deps, create keys dir, copy env)"
task :setup do
  sh "bash setup.sh"
end

desc "Generate private key"
task :keygen, [:path] do |t, args|
  path = args[:path] || './keys/node.key'
  sh "ruby node-agent/bin/keygen -p #{path}"
end

desc "Run node agent"
task :run do
  sh "ruby node-agent/bin/node-agent"
end

desc "Run as daemon"
task :daemon do
  require 'daemons'
  Daemons.run('node-agent/bin/node-agent')
end

desc "Build Docker image"
task :docker_build, [:tag] do |t, args|
  tag = args[:tag] || 'latest'
  sh "docker build -t vpn-node:#{tag} ."
end

desc "Run with Docker Compose"
task :docker_up do
  sh "docker-compose up -d"
end

desc "Stop Docker Compose"
task :docker_down do
  sh "docker-compose down"
end

desc "View Docker logs"
task :docker_logs do
  sh "docker-compose logs -f"
end

desc "Claim reward for specific epoch"
task :claim_reward, [:epoch] do |t, args|
  if args[:epoch]
    sh "ruby node-agent/bin/claim-reward -e #{args[:epoch]}"
  else
    sh "ruby node-agent/bin/claim-reward"
  end
end

desc "Verify reward for epoch"
task :verify_reward, [:epoch] do |t, args|
  raise "Epoch is required" unless args[:epoch]
  sh "ruby node-agent/bin/verify-reward -e #{args[:epoch]}"
end

desc "Test reward claimer (quick test)"
task :test_reward_claimer do
  sh "ruby test_reward_claimer_quick.rb"
end

desc "Test reward claimer (full test with backend)"
task :test_reward_claimer_full do
  sh "ruby test_reward_claimer_simple.rb"
end

