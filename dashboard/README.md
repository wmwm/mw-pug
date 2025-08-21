# MW-PUG Analytics Dashboard

The Analytics Dashboard is a web-based interface for monitoring and analyzing the notification system and other aspects of the MW-PUG bot.

## Features

- Real-time notification metrics
- User engagement analytics
- Server health monitoring
- Performance statistics

## Tech Stack

- Next.js
- React
- Material UI
- Chart.js

## Getting Started

### Prerequisites

- Node.js 16.x or later
- npm 8.x or later

### Installation

1. Install dependencies:
   ```bash
   cd dashboard
   npm install
   ```

2. Run the development server:
   ```bash
   npm run dev
   ```

3. Open [http://localhost:3000](http://localhost:3000) in your browser.

## Development

### Directory Structure

- `/components` - Reusable React components
- `/pages` - Next.js pages and routes
- `/api` - API endpoints
- `/styles` - Global styles and theme

### Available Scripts

- `npm run dev` - Start the development server
- `npm run build` - Build the production application
- `npm run start` - Start the production server
- `npm run lint` - Lint the codebase
- `npm run test` - Run the test suite

## API Documentation

The dashboard connects to the following API endpoints:

- `/api/notification-stats` - Get notification system statistics
- `/api/user-engagement` - Get user engagement metrics (coming soon)
- `/api/server-health` - Get server health metrics (coming soon)
- `/api/performance` - Get system performance metrics (coming soon)

## Contributing

Follow the same contribution guidelines as the main MW-PUG project.
