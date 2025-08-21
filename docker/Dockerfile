FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y     wget     unzip     screen     --no-install-recommends &&     rm -rf /var/lib/apt/lists/*

# Create FortressOne directory
WORKDIR /opt/fortressone

# Download FortressOne server binaries
# Using a specific release for stability
ARG FORTRESSONE_VERSION=v1.0.4
RUN wget -O fortress-one.tar.gz https://github.com/FortressOne/server-qwprogs/releases/download/${FORTRESSONE_VERSION}/fortress-one-linux-x64.tar.gz &&     tar -xzf fortress-one.tar.gz &&     chmod +x mvdsv

# Create maps directory
RUN mkdir -p fortress/maps

# Expose game port
EXPOSE 27500/udp

# Default command to run the server
# This will be overridden by the user_data script
CMD ["./mvdsv", "+set", "hostname", "Pug Fortress", "+exec", "fo_quadmode.cfg", "+map", "mbasesr"]
