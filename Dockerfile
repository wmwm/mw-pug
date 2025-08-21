# Use official Ruby image
FROM ruby:3.2.2

# Set working directory
WORKDIR /app

# Copy Gemfile and Gemfile.lock first for better caching
COPY Gemfile Gemfile.lock ./

# Install dependencies
RUN bundle install

# Copy the rest of the application
COPY . .

# Expose port (Railway will set PORT environment variable)
EXPOSE 3000

# Run the bot
CMD ["bundle", "exec", "ruby", "bot/pugbot.rb"]
