import AsyncStorage from '@react-native-async-storage/async-storage';
import { WeatherData, Location } from '@/types/weather';

const API_KEY = 'YOUR_PIRATE_WEATHER_API_KEY'; // Replace with your actual API key
const BASE_URL = 'https://api.pirateweather.net/forecast';

export const fetchWeatherData = async (
  latitude: number,
  longitude: number
): Promise<WeatherData> => {
  try {
    // Try to get cached data first
    const cachedData = await getCachedWeatherData(latitude, longitude);
    if (cachedData) {
      const parsedData = JSON.parse(cachedData);
      const cacheTime = parsedData.cacheTime;
      
      // If cache is less than 30 minutes old, use it
      if (Date.now() - cacheTime < 30 * 60 * 1000) {
        return parsedData.data;
      }
    }

    // Fetch fresh data if no cache or cache is old
    const url = `${BASE_URL}/${API_KEY}/${latitude},${longitude}?exclude=flags&units=us`;
    const response = await fetch(url);
    
    if (!response.ok) {
      throw new Error(`Weather API error: ${response.status}`);
    }
    
    const data = await response.json();
    
    // Transform API response to our app's data structure
    const weatherData: WeatherData = {
      current: {
        temperature: data.currently.temperature,
        feelsLike: data.currently.apparentTemperature,
        humidity: data.currently.humidity,
        windSpeed: data.currently.windSpeed,
        windDirection: data.currently.windBearing,
        pressure: data.currently.pressure,
        uvIndex: data.currently.uvIndex,
        visibility: data.currently.visibility,
        icon: data.currently.icon,
        summary: data.currently.summary,
        time: data.currently.time,
      },
      hourly: data.hourly.data.map((hour: any) => ({
        time: hour.time,
        temperature: hour.temperature,
        feelsLike: hour.apparentTemperature,
        precipProbability: hour.precipProbability,
        precipIntensity: hour.precipIntensity,
        precipType: hour.precipType || null,
        humidity: hour.humidity,
        windSpeed: hour.windSpeed,
        windDirection: hour.windBearing,
        uvIndex: hour.uvIndex,
        icon: hour.icon,
        summary: hour.summary,
      })),
      daily: data.daily.data.map((day: any) => ({
        time: day.time,
        temperatureHigh: day.temperatureHigh,
        temperatureLow: day.temperatureLow,
        precipProbability: day.precipProbability,
        precipIntensity: day.precipIntensity,
        precipType: day.precipType || null,
        humidity: day.humidity,
        windSpeed: day.windSpeed,
        windDirection: day.windBearing,
        uvIndex: day.uvIndex,
        icon: day.icon,
        summary: day.summary,
        sunriseTime: day.sunriseTime,
        sunsetTime: day.sunsetTime,
      })),
      alerts: data.alerts ? data.alerts.map((alert: any) => ({
        title: alert.title,
        description: alert.description,
        severity: alert.severity,
        time: alert.time,
        expires: alert.expires,
      })) : undefined,
      minutely: data.minutely ? data.minutely.data.map((minute: any) => ({
        time: minute.time,
        precipProbability: minute.precipProbability,
        precipIntensity: minute.precipIntensity,
      })) : undefined,
    };
    
    // Cache the data
    await cacheWeatherData(latitude, longitude, weatherData);
    
    return weatherData;
  } catch (error) {
    console.error('Error fetching weather data:', error);
    throw error;
  }
};

const getCachedWeatherData = async (
  latitude: number,
  longitude: number
): Promise<string | null> => {
  try {
    const key = `weather_${latitude.toFixed(4)}_${longitude.toFixed(4)}`;
    return await AsyncStorage.getItem(key);
  } catch (error) {
    console.error('Error getting cached weather data:', error);
    return null;
  }
};

const cacheWeatherData = async (
  latitude: number,
  longitude: number,
  data: WeatherData
): Promise<void> => {
  try {
    const key = `weather_${latitude.toFixed(4)}_${longitude.toFixed(4)}`;
    const cacheData = {
      data,
      cacheTime: Date.now(),
    };
    await AsyncStorage.setItem(key, JSON.stringify(cacheData));
  } catch (error) {
    console.error('Error caching weather data:', error);
  }
};

export const fetchLocationFromCoordinates = async (
  latitude: number,
  longitude: number
): Promise<string> => {
  try {
    const response = await fetch(
      `https://nominatim.openstreetmap.org/reverse?format=json&lat=${latitude}&lon=${longitude}&zoom=10`
    );
    
    if (!response.ok) {
      throw new Error(`Geocoding API error: ${response.status}`);
    }
    
    const data = await response.json();
    
    // Extract city and state/country
    const address = data.address;
    const city = address.city || address.town || address.village || address.hamlet;
    const state = address.state || address.country;
    
    return city ? `${city}, ${state}` : state;
  } catch (error) {
    console.error('Error fetching location name:', error);
    return `${latitude.toFixed(2)}, ${longitude.toFixed(2)}`;
  }
};

export const searchLocations = async (query: string): Promise<Location[]> => {
  try {
    const response = await fetch(
      `https://nominatim.openstreetmap.org/search?format=json&q=${encodeURIComponent(query)}&limit=5`
    );
    
    if (!response.ok) {
      throw new Error(`Location search API error: ${response.status}`);
    }
    
    const data = await response.json();
    
    return data.map((item: any) => ({
      id: item.place_id.toString(),
      name: item.display_name.split(',').slice(0, 2).join(','),
      latitude: parseFloat(item.lat),
      longitude: parseFloat(item.lon),
      isCurrent: false,
    }));
  } catch (error) {
    console.error('Error searching locations:', error);
    return [];
  }
};
