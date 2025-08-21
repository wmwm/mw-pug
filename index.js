require('dotenv').config();
const { Client, GatewayIntentBits, REST, Routes, SlashCommandBuilder } = require('discord.js');

const client = new Client({ intents: [GatewayIntentBits.Guilds] });

const commands = [
  new SlashCommandBuilder().setName('join').setDescription('Join the lobby'),
  new SlashCommandBuilder().setName('leave').setDescription('Leave the lobby'),
  new SlashCommandBuilder().setName('status').setDescription('Show current lobby status'),
  new SlashCommandBuilder().setName('start').setDescription('Start the match'),
].map(cmd => cmd.toJSON());

const rest = new REST({ version: '10' }).setToken(process.env.DISCORD_TOKEN);

client.once('ready', async () => {
  console.log(`✅ Logged in as ${client.user.tag}`);
  await rest.put(Routes.applicationGuildCommands(client.user.id, process.env.GUILD_ID), { body: commands });
  console.log('✅ Slash commands registered to guild.');
});

let lobby = [];

client.on('interactionCreate', async interaction => {
  if (!interaction.isChatInputCommand()) return;

  const { commandName, user } = interaction;

  if (commandName === 'join') {
    if (!lobby.includes(user.username)) lobby.push(user.username);
    await interaction.reply(`${user.username} joined the lobby.`);
  }

  if (commandName === 'leave') {
    lobby = lobby.filter(name => name !== user.username);
    await interaction.reply(`${user.username} left the lobby.`);
  }

  if (commandName === 'status') {
    await interaction.reply(`Current lobby: ${lobby.join(', ') || 'empty'}`);
  }

  if (commandName === 'start') {
    if (lobby.length < 2) {
      await interaction.reply('Need at least 2 players to start.');
    } else {
      const teams = [[], []];
      lobby.forEach((player, i) => teams[i % 2].push(player));
      await interaction.reply(`Match started!\nTeam 1: ${teams[0].join(', ')}\nTeam 2: ${teams[1].join(', ')}`);
      lobby = [];
    }
  }
});

client.login(process.env.DISCORD_TOKEN);
