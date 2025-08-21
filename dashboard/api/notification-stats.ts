// Next.js API route support: https://nextjs.org/docs/api-routes/introduction
import type { NextApiRequest, NextApiResponse } from 'next';

type NotificationStats = {
  total_sent: number;
  success_rate: number;
  tier_distribution: {
    tier0: number;
    tier1: number;
    tier2: number;
  };
  fallback_rate: number;
  avg_response_time_seconds: number;
};

// Mock data for initial development
const MOCK_DATA: NotificationStats = {
  total_sent: 12458,
  success_rate: 0.97,
  tier_distribution: {
    tier0: 0.15,
    tier1: 0.45,
    tier2: 0.40
  },
  fallback_rate: 0.03,
  avg_response_time_seconds: 31.5
};

export default function handler(
  req: NextApiRequest,
  res: NextApiResponse<NotificationStats>
) {
  // In a real implementation, this would fetch data from the database
  res.status(200).json(MOCK_DATA);
}
