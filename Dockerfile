FROM ruby:3.2

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs

# Set working directory
WORKDIR /app

# Expose ports
EXPOSE 35729 4000

CMD ["bash"]
