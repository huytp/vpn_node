FROM ruby:3.2.0-slim

# Install WireGuard and dependencies
RUN apt-get update -qq && apt-get install -y \
  wireguard \
  wireguard-tools \
  build-essential \
  curl \
  git \
  libssl-dev \
  pkg-config \
  wget \
  unzip \
  ca-certificates \
  autoconf \
  automake \
  libtool \
  && rm -rf /var/lib/apt/lists/*

# Pre-install libsecp256k1 to avoid download issues during gem install
RUN cd /tmp && \
  git clone https://github.com/bitcoin-core/secp256k1.git && \
  cd secp256k1 && \
  ./autogen.sh && \
  ./configure --enable-module-recovery --prefix=/usr/local && \
  make && \
  make install && \
  ldconfig && \
  cd / && \
  rm -rf /tmp/secp256k1

WORKDIR /app

# Copy Gemfile first for better caching
COPY Gemfile Gemfile.lock* ./

# Install gems with retry and longer timeout
RUN bundle config set --local retry 3 && \
  bundle config set --local timeout 300 && \
  bundle install --without development

# Copy application
COPY . .

# Create keys directory
RUN mkdir -p /app/keys && \
  chmod 700 /app/keys

# Make scripts executable
RUN chmod +x node-agent/bin/*

# Health check
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD pgrep -f "node-agent" || exit 1

# Run
CMD ["ruby", "node-agent/bin/node-agent"]
