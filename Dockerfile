#
# Dockerfile for eve-posbot.
#
# This is done as a two-stage build so that we can use the full Ruby image
# to build the application and the native extensions for some of the dependency
# gems, then deploy using the slim Ruby image. This reduces the resulting image
# by about 250MB, although of course most of that is shared with other
# Ruby deployments.
#
FROM ruby:2.4 as build-env

MAINTAINER Bora Vyvorant <bora.vyvorant@gmail.com>

# throw errors if Gemfile has been modified since Gemfile.lock
RUN bundle config --global frozen 1

WORKDIR /app

#
# Install dependencies.
#
COPY Gemfile Gemfile.lock ./
RUN bundle install --deployment --without=devel

COPY posbot.rb ./

#
# Production image build using the slim Ruby image.
#
FROM ruby:2.4-slim as production

MAINTAINER Bora Vyvorant <bora.vyvorant@gmail.com>

WORKDIR /app

#
# Install binary dependencies that are not provided by the -slim version
# of the Ruby image.
#
RUN apt-get update && \
    apt-get install -y \
        libcurl4-openssl-dev && \
    rm -rf /var/lib/apt/lists/*

#
# Pull across the bundler configuration from the build environment.
#
COPY --from=build-env $BUNDLE_APP_CONFIG $BUNDLE_APP_CONFIG

#
# Pull across the actual application from the build environment.
#
COPY --from=build-env /app .

#
# Add any .yaml files we happen to have handy. In the context of the
# base GitHub repository, that will just be example-config.yaml.
#
COPY *.yaml ./

#
# By default, just run the script against the default configuration
# file "config.yaml". Note that we haven't necessarily copied one of these
# into the image yet. Some alternative approaches are:
#
# * Perform this build in a directory containing your desired configuration.
#
# * Make an image of your own just adding a layer with config.yaml in it
#   (the CMD below will still apply, unless you change it).
#
# * Bind-mount your config.yaml into the container when you create it.
#
# The ENTRYPOINT/CMD combination means that you can treat this container
# like an executable, and add more parameters on the command line if
# required, for example to indicate a specific configuration file name.
#
# If you need to debug the container, you will need to override all this
# with --entrypoint.
#
ENTRYPOINT ["bundle", "exec", "ruby", "posbot.rb"]
CMD []
