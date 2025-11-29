FROM node:20-bullseye

WORKDIR /srv/app

# Install OS dependencies required for better-sqlite3
RUN apt-get update && apt-get install -y \
    python3 \
    make \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Copy only package files for caching
COPY package*.json ./

# Install node dependencies
RUN npm install
RUN npm install mysql2 --save
# Copy full project
COPY . .

# Build Strapi admin
RUN npm run build

EXPOSE 1337

CMD ["npm", "start"]