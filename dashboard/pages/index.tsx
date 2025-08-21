import React from 'react';
import Head from 'next/head';
import { Container, Typography, Box, Grid } from '@mui/material';

export default function Home() {
  return (
    <div>
      <Head>
        <title>MW-PUG Analytics Dashboard</title>
        <meta name="description" content="Analytics dashboard for MW-PUG bot" />
        <link rel="icon" href="/favicon.ico" />
      </Head>

      <Container maxWidth="lg">
        <Box sx={{ my: 4 }}>
          <Typography variant="h2" component="h1" gutterBottom>
            MW-PUG Analytics Dashboard
          </Typography>
          <Typography variant="h5" component="h2" gutterBottom>
            Notification System Metrics
          </Typography>

          <Grid container spacing={3} sx={{ mt: 3 }}>
            <Grid item xs={12} md={6}>
              <Box
                sx={{
                  p: 3,
                  border: '1px solid #ccc',
                  borderRadius: 2,
                  height: '300px',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                }}
              >
                <Typography variant="body1">Notification Delivery Success Chart (Coming Soon)</Typography>
              </Box>
            </Grid>
            <Grid item xs={12} md={6}>
              <Box
                sx={{
                  p: 3,
                  border: '1px solid #ccc',
                  borderRadius: 2,
                  height: '300px',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                }}
              >
                <Typography variant="body1">Response Time Distribution (Coming Soon)</Typography>
              </Box>
            </Grid>
            <Grid item xs={12} md={4}>
              <Box
                sx={{
                  p: 3,
                  border: '1px solid #ccc',
                  borderRadius: 2,
                  height: '200px',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                }}
              >
                <Typography variant="body1">Tier Distribution (Coming Soon)</Typography>
              </Box>
            </Grid>
            <Grid item xs={12} md={4}>
              <Box
                sx={{
                  p: 3,
                  border: '1px solid #ccc',
                  borderRadius: 2,
                  height: '200px',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                }}
              >
                <Typography variant="body1">Fallback Rate (Coming Soon)</Typography>
              </Box>
            </Grid>
            <Grid item xs={12} md={4}>
              <Box
                sx={{
                  p: 3,
                  border: '1px solid #ccc',
                  borderRadius: 2,
                  height: '200px',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                }}
              >
                <Typography variant="body1">User Engagement (Coming Soon)</Typography>
              </Box>
            </Grid>
          </Grid>
        </Box>
      </Container>
    </div>
  );
}
