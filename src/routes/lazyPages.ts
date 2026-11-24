import { lazyWithRetry } from '../utils/lazyWithRetry';

export const Plan = lazyWithRetry(() => import('../pages/Plan'), 'Plan');
export const Forecast = lazyWithRetry(() => import('../pages/Forecast'), 'Forecast');
export const Supplies = lazyWithRetry(() => import('../pages/Supplies'), 'Supplies');
export const History = lazyWithRetry(() => import('../pages/History'), 'History');
export const Lab = lazyWithRetry(() => import('../pages/Lab'), 'Lab');
export const CalibrationSettings = lazyWithRetry(() => import('../pages/CalibrationSettings'), 'CalibrationSettings');
export const Settings = lazyWithRetry(() => import('../pages/Settings'), 'Settings');
export const PKParamsPage = lazyWithRetry(() => import('../pages/PKParams'), 'PKParams');
export const HRTModeSettings = lazyWithRetry(() => import('../pages/HRTModeSettings'), 'HRTModeSettings');
export const LanguageSettings = lazyWithRetry(() => import('../pages/LanguageSettings'), 'LanguageSettings');
export const AppearanceSettings = lazyWithRetry(() => import('../pages/AppearanceSettings'), 'AppearanceSettings');
export const WeightSettings = lazyWithRetry(() => import('../pages/WeightSettings'), 'WeightSettings');
export const AgeSettings = lazyWithRetry(() => import('../pages/AgeSettings'), 'AgeSettings');
export const ExportSettings = lazyWithRetry(() => import('../pages/ExportSettings'), 'ExportSettings');
export const ImportSettings = lazyWithRetry(() => import('../pages/ImportSettings'), 'ImportSettings');
export const TransparencySettings = lazyWithRetry(
    () => import('../pages/TransparencySettings'),
    'TransparencySettings',
);
export const Credits = lazyWithRetry(() => import('../pages/Credits'), 'Credits');
export const CommunityVote = lazyWithRetry(() => import('../pages/CommunityVote'), 'CommunityVote');
export const Disclaimer = lazyWithRetry(() => import('../pages/Disclaimer'), 'Disclaimer');
export const OpSec = lazyWithRetry(() => import('../pages/OpSec'), 'OpSec');
export const PKDemos = lazyWithRetry(() => import('../pages/PKDemos'), 'PKDemos');
export const ModelGuide = lazyWithRetry(() => import('../pages/ModelGuide'), 'ModelGuide');
export const CalibrationGuide = lazyWithRetry(() => import('../pages/CalibrationGuide'), 'CalibrationGuide');
export const MilkTeaEasterEgg = lazyWithRetry(() => import('../pages/MilkTeaEasterEgg'), 'MilkTeaEasterEgg');
export const CatStates = lazyWithRetry(() => import('../pages/CatStates'), 'CatStates');
export const Simulator = lazyWithRetry(() => import('../pages/Simulator'), 'Simulator');
